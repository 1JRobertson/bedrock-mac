//! One stable executable owns sign-in, licensed download, and Xbox IPC.
//! Credentials stay in Keychain. Never log raw service errors or panic payloads.
use std::{collections::{HashMap, HashSet}, path::{Component, Path, PathBuf}, process::ExitCode, sync::{Arc, atomic::{AtomicUsize, Ordering}}};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use futures_util::{stream, StreamExt, TryStreamExt};
use msixvc::{streaming, xvd::{SegmentFile, XvdFile}};
use tokio::{fs::{File, OpenOptions}, io::AsyncReadExt};
use xodus::tokens::{TokenManager, store::TokenStoreError};

#[path = "../src/webview.rs"] mod webview;
#[path = "../src/commands/login.rs"] mod login;
#[path = "../src/package.rs"] mod package;
#[path = "../src/license.rs"] mod license;

type Outcome<T> = Result<T, Box<dyn std::error::Error>>;
const PRODUCT: &str = "9NBLGGH2JHXJ";

fn safe_relative(name: &str) -> Outcome<PathBuf> {
    let normalized = name.replace('\\', "/");
    let relative = Path::new(&normalized);
    if normalized.is_empty() || normalized.contains(':') || normalized.contains('\0')
        || relative.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err("The package contains an unsafe file path.".into());
    }
    Ok(relative.to_path_buf())
}

async fn check_game(directory: &Path) -> Outcome<()> {
    let mut exe = File::open(directory.join("Minecraft.Windows.exe")).await
        .map_err(|_| "Minecraft.Windows.exe is missing.")?;
    let mut signature = [0; 2];
    exe.read_exact(&mut signature).await?;
    if &signature != b"MZ" || !directory.join("MicrosoftGame.Config").is_file()
        || !directory.join(".xodus-streaming.msixvc").is_file() {
        return Err("The game is not a prepared Windows Store installation.".into());
    }
    Ok(())
}

async fn authorize_game(client: &reqwest::Client, tokens: &TokenManager, directory: &Path, market: &str) -> Outcome<()> {
    // An already prepared executable still requires this account's real license.
    // Do not turn a copied installation into an ownership substitute.
    let mut metadata = File::open(directory.join(".xodus-streaming.msixvc")).await?;
    let xvd = XvdFile::parse(&mut metadata).await?;
    let (device_key, owned_license) = license::get_license(client, tokens, xvd.content_id().to_string(), market.into()).await
        .map_err(|_| "Microsoft did not grant a Minecraft content license to this account.")?;
    if owned_license.content_keys.len() != 1 { return Err("Microsoft returned an unsupported content license.".into()); }
    let content_key = owned_license.content_keys.into_values().next().ok_or("Content key missing.")?;
    let _key = content_key.unpack(&device_key).map_err(|_| "Could not open the owner's content license.")?;
    Ok(())
}

async fn download(client: &reqwest::Client, tokens: &TokenManager, directory: &Path, market: &str) -> Outcome<()> {
    if directory.symlink_metadata().is_ok() {
        return Err("The download destination must not exist; existing games are never overwritten.".into());
    }
    let parent = directory.parent().ok_or("A destination parent directory is required.")?;
    std::fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new().prefix(".bedrock-download-").tempdir_in(parent)?;
    let out = staging.path();
    eprintln!("Finding the Windows package for the signed-in owner's Minecraft purchase.");
    let content_id = package::get_content_id(client, PRODUCT.into(), Some(market.into())).await
        .map_err(|_| "Microsoft did not return a Windows Minecraft package.")?;
    let details = package::get_packages(client, tokens, content_id).await
        .map_err(|_| "Microsoft did not return a package available to this account.")?;
    let packages: Vec<_> = details.package_files.iter().filter(|p| p.file_name.ends_with(".msixvc")).collect();
    if packages.len() != 1 { return Err("Expected one Windows MSIXVC package; selection requires review.".into()); }
    let package = packages[0];
    let cdn = package.cdn_root_paths.first().ok_or("Microsoft supplied no package download location.")?;
    let url = format!("{}{}", cdn, package.relative_url);
    let url = url.strip_prefix("http://").map(|rest| format!("https://{rest}")).unwrap_or(url);
    if !url.starts_with("https://") { return Err("The package download must use HTTPS.".into()); }
    let http = streaming::HttpRead::open(client.clone(), &url, None::<fn(u64, u64)>).await
        .map_err(|_| "Could not open the Microsoft package download.")?;
    if package.file_size <= 0 || http.len() != package.file_size as u64 {
        return Err("The package download size does not match Microsoft's metadata.".into());
    }
    let mut metadata = streaming::PrefixCacheFile::new(http, package.file_size as u64, out.join(".xodus-streaming.msixvc")).await?;
    let xvd = XvdFile::parse(&mut metadata).await?;
    let mut files: HashMap<String, SegmentFile> = HashMap::new();
    for (name, segment) in xvd.parse_user_package_files(&mut metadata).await? {
        if name == "SegmentMetadata.bin" { files.extend(xvd.parse_segment_metadata(&mut metadata, &segment).await?); }
    }
    files.extend(xvd.parse_ntfs_segment_metadata(&mut metadata, !files.is_empty()).await?);
    xvd.populate_segment_hashes(&mut files)?;
    if !files.contains_key("Minecraft.Windows.exe") { return Err("The package is not the expected Windows Minecraft game.".into()); }
    let mut names = HashSet::new();
    let mut required: u64 = 512 * 1024 * 1024;
    for (name, info) in &files {
        let relative = safe_relative(name)?;
        let normalized = relative.to_string_lossy().to_lowercase();
        if !names.insert(normalized.clone()) || normalized.starts_with(".xodus-") {
            return Err("The package contains conflicting or reserved file paths.".into());
        }
        required = required.checked_add(info.length).ok_or("Package size overflow.")?;
        if info.keep_encrypted {
            required = required.checked_add(info.length + 4096).ok_or("Package size overflow.")?;
            for extension in ["xodus-encrypted", "standalone-preparing"] {
                if !names.insert(relative.with_extension(extension).to_string_lossy().to_lowercase()) {
                    return Err("The package conflicts with an executable preparation path.".into());
                }
            }
        }
    }
    if fs2::available_space(out)? < required { return Err("There is not enough free space to download and prepare Minecraft.".into()); }
    let (device_key, owned_license) = license::get_license(client, tokens, xvd.content_id().to_string(), market.into()).await
        .map_err(|_| "Microsoft did not grant a Minecraft content license to this account.")?;
    if owned_license.content_keys.len() != 1 { return Err("Microsoft returned an unsupported content license.".into()); }
    let content_key = owned_license.content_keys.into_values().next().ok_or("Content key missing.")?;
    let key = content_key.unpack(&device_key).map_err(|_| "Could not open the owner's content license.")?;
    eprintln!("Downloading Minecraft {} ({} files).", details.version, files.len());
    let completed = AtomicUsize::new(0);
    let total = files.len();
    stream::iter(files.iter()).map(|(name, info)| {
        let xvd = &xvd;
        let key = &key;
        let url = &url;
        let completed = &completed;
        async move {
            let relative = safe_relative(name)?;
            let target = out.join(&relative);
            std::fs::create_dir_all(target.parent().ok_or("Missing output parent.")?)?;
            let mut output = OpenOptions::new().write(true).create_new(true).open(&target).await?;
            tokio::time::timeout(std::time::Duration::from_secs(900),
                xvd.download_file_http(client, url, &mut output, info, **key, |_, _| {})).await
                .map_err(|_| "A game file download timed out; retry setup.")?
                .map_err(|_| "A game file download failed; retry setup.")?;
            output.sync_all().await?;
            drop(output);
            // Encrypted files preserve complete 4 KiB cipher blocks until preparation.
            let stored_length = if info.keep_encrypted { info.length.div_ceil(4096) * 4096 } else { info.length };
            if target.metadata()?.len() != stored_length { return Err("A game file has an unexpected size.".into()); }
            if info.keep_encrypted {
                let mut input = File::open(&target).await?;
                let prepared = target.with_extension("standalone-preparing");
                let mut output = OpenOptions::new().write(true).create_new(true).open(&prepared).await?;
                xvd.mount_mem_fd(&mut input, &mut output, info, **key, |_, _| {}).await
                    .map_err(|_| "Licensed executable preparation failed.")?;
                output.sync_all().await?;
                drop(output);
                if prepared.metadata()?.len() != info.length { return Err("The prepared executable has an unexpected size.".into()); }
                let mut check = File::open(&prepared).await?;
                let mut signature = [0; 2];
                check.read_exact(&mut signature).await?;
                if &signature != b"MZ" { return Err("The prepared executable has an invalid signature.".into()); }
                drop(check);
                std::fs::rename(&target, target.with_extension("xodus-encrypted"))?;
                std::fs::rename(&prepared, &target)?;
            }
            let count = completed.fetch_add(1, Ordering::Relaxed) + 1;
            if count % 500 == 0 || count == total { eprintln!("Downloaded {count}/{total} files."); }
            Ok::<(), Box<dyn std::error::Error>>(())
        }
    }).buffer_unordered(4).try_collect::<Vec<_>>().await?;
    drop(metadata);
    check_game(out).await?;
    if directory.symlink_metadata().is_ok() { return Err("The destination appeared during download; refusing to replace it.".into()); }
    std::fs::rename(out, directory)?;
    eprintln!("Minecraft is downloaded and prepared using the owner's Microsoft license.");
    Ok(())
}

async fn run() -> Outcome<()> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or("Use --download GAME_DIR or --serve GAME_DIR [--market CA].")?;
    if mode == "--help" {
        println!("standalone_helper --download GAME_DIR [--market CA] [--serve-after]\nstandalone_helper --serve GAME_DIR [--market CA]\nCredentials: macOS Keychain, Minecraft Bedrock Standalone. Stop any existing Xbox helper first.");
        return Ok(());
    }
    if mode != "--download" && mode != "--serve" { return Err("Unknown helper mode.".into()); }
    let directory = PathBuf::from(args.next().ok_or("Game directory required.")?);
    let directory = if directory.is_absolute() { directory } else { std::env::current_dir()?.join(directory) };
    let mut market = String::from("CA");
    let mut serve = mode == "--serve";
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--market" => market = args.next().ok_or("Market code required.")?,
            "--serve-after" if mode == "--download" => serve = true,
            _ => return Err("Unknown helper option.".into()),
        }
    }
    if market.len() != 2 || !market.bytes().all(|b| b.is_ascii_uppercase()) { return Err("Market must be a two-letter uppercase country code.".into()); }
    if Path::new("/tmp/xodus.sock").symlink_metadata().is_ok() {
        return Err("An Xbox service socket already exists. Close the game and stop its helper first; this helper never replaces it.".into());
    }
    if mode == "--serve" { check_game(&directory).await?; }
    else if directory.symlink_metadata().is_ok() { return Err("Download destination already exists; choose a new directory.".into()); }
    // A download does not create the IPC socket yet, so also serialize account access.
    let support = PathBuf::from(std::env::var_os("HOME").ok_or("Home directory is unavailable.")?)
        .join("Library/Application Support/Minecraft Bedrock Standalone");
    if support.is_symlink() { return Err("The standalone helper state directory must not be a symbolic link.".into()); }
    std::fs::create_dir_all(&support)?;
    std::fs::set_permissions(&support, std::fs::Permissions::from_mode(0o700))?;
    let lock_path = support.join("account.lock");
    if lock_path.is_symlink() { return Err("The account lock must not be a symbolic link.".into()); }
    let account_lock = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(lock_path)?;
    fs2::FileExt::try_lock_exclusive(&account_lock).map_err(|_| "Another standalone account helper is already running.")?;
    xodus::secrets::init_named_secrets("Minecraft Bedrock Standalone")
        .map_err(|_| "Could not initialize macOS Keychain.")?;
    let tokens = Arc::new(TokenManager::with_keychain_and_memory());
    let client = reqwest::Client::builder().user_agent("bedrock-mac-standalone/0.1").https_only(true)
        .connect_timeout(std::time::Duration::from_secs(30)).build()?;
    xodus::tokens::device::ensure_device_credentials(&client, &tokens).await;
    match tokens.get_user() {
        Ok(_) => {},
        Err(TokenStoreError::NotFound) => {
            eprintln!("Sign in with the Microsoft account that owns Minecraft: Java & Bedrock for PC.");
            if login::run(&client, &tokens).await != ExitCode::SUCCESS { return Err("Microsoft sign-in was not completed.".into()); }
        },
        Err(_) => return Err("Could not read the saved Microsoft sign-in from Keychain.".into()),
    }
    tokens.get_user_sts_token().map_err(|_| "Microsoft sign-in is unavailable.")?;
    if mode == "--download" {
        download(&client, &tokens, &directory, &market).await
            .map_err(|_| "Minecraft download or licensed preparation failed. Check ownership, network access, and available space, then retry. No existing installation was changed.")?;
    } else {
        eprintln!("Verifying this account's Microsoft license for the installed game.");
        authorize_game(&client, &tokens, &directory, &market).await
            .map_err(|_| "Microsoft could not verify this account's license for the installed Minecraft game. Sign in with the owning account and check the network connection.")?;
    }
    if serve {
        eprintln!("Starting Xbox account service.");
        xodus_service::run(tokens).await;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    // Upstream panic payloads can contain request/response data. Never emit them.
    std::panic::set_hook(Box::new(|_| eprintln!("The Microsoft account helper stopped unexpectedly; no account details were logged.")));
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => { eprintln!("Setup failed: {error}"); ExitCode::FAILURE },
    }
}

#[cfg(test)]
mod tests {
    use super::safe_relative;
    #[test]
    fn package_paths_cannot_escape_destination() {
        for path in ["", "../file", "C:\\file", "/tmp/file", "dir\\..\\file", "file:stream", "bad\0name"] {
            assert!(safe_relative(path).is_err(), "{path:?}");
        }
        assert_eq!(safe_relative("Installers\\GameInputRedist.msi").unwrap().to_str(), Some("Installers/GameInputRedist.msi"));
    }
}
