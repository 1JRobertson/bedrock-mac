//! One stable executable owns sign-in, licensed download, and Xbox IPC.
//! Credentials stay in Keychain. Never log raw service errors or panic payloads.
use std::{collections::{HashMap, HashSet}, path::{Component, Path, PathBuf}, process::ExitCode, sync::{Arc, atomic::{AtomicUsize, Ordering}}};
use std::os::unix::{ffi::OsStrExt, fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt}};
use futures_util::{stream, StreamExt, TryStreamExt};
use msixvc::{streaming, xvd::{SegmentFile, XvdFile}};
use tokio::{fs::{File, OpenOptions}, io::{AsyncReadExt, AsyncSeekExt}};
use xodus::models::{secrets::Token, soap::BodyContent};
use xodus::tokens::{TokenManager, store::TokenStoreError};

#[path = "../src/webview.rs"] mod webview;
#[path = "../src/commands/login.rs"] mod login;
#[path = "../src/package.rs"] mod package;
#[path = "../src/license.rs"] mod license;

type Outcome<T> = Result<T, Box<dyn std::error::Error>>;
const PRODUCT: &str = "9NBLGGH2JHXJ";

fn usable_sts(token: &Token, now: chrono::DateTime<chrono::Utc>) -> bool {
    match token {
        Token::Legacy(token) if !token.token.is_empty() => chrono::DateTime::parse_from_rfc3339(&token.lifetime.expires)
            .is_ok_and(|expires| expires.timestamp() > now.timestamp() + 60),
        _ => false,
    }
}

fn login_needed(tokens: &TokenManager, now: chrono::DateTime<chrono::Utc>) -> Outcome<bool> {
    let profile_present = match tokens.get_user() {
        Ok(_) => true,
        Err(TokenStoreError::NotFound) => false,
        Err(_) => return Err("Could not read the saved Microsoft profile from Keychain; no credentials were changed.".into()),
    };
    let token_usable = match tokens.get_user_sts_token() {
        Ok(token) => usable_sts(&token, now),
        Err(TokenStoreError::NotFound) => false,
        Err(_) => return Err("Could not read the saved Microsoft sign-in from Keychain; no credentials were changed.".into()),
    };
    Ok(!profile_present || !token_usable)
}

async fn ensure_device(client: &reqwest::Client, tokens: &TokenManager) -> Outcome<()> {
    let license = match tokens.get_device_license() {
        Ok(license) => license,
        Err(TokenStoreError::NotFound) => {
            // Only a genuinely absent entry permits provisioning a new identity.
            // Keychain denial/corruption must never silently replace an existing one.
            xodus::tokens::device::ensure_device_credentials(client, tokens).await;
            return match tokens.get_device_sts_token() {
                Ok(token) if usable_sts(&token, chrono::Utc::now()) => Ok(()),
                _ => Err("Microsoft device registration did not yield a usable sign-in token.".into()),
            };
        },
        Err(_) => return Err("Could not read the saved device identity from Keychain; it was preserved.".into()),
    };
    match tokens.get_device_sts_token() {
        Ok(token) if usable_sts(&token, chrono::Utc::now()) => return Ok(()),
        Ok(_) | Err(TokenStoreError::NotFound) => {},
        Err(_) => return Err("Could not read the saved device sign-in from Keychain; it was preserved.".into()),
    }
    let parsed = xodus::licensing::splicense::SPLicense::parse_base64(&license.splicense)
        .map_err(|_| "The saved device license could not be read; it was preserved.")?;
    let state = parsed.clep_sign_state.ok_or("The saved device license lacks its signing state.")?;
    let key = xodus::licensing::utils::parse_bcrypt_rsa_private(&state.get_rsa_key())
        .map_err(|_| "The saved device key could not be read; it was preserved.")?;
    let response = xodus::api::live::authenticate_device(client, license.username, key).await
        .map_err(|_| "Microsoft could not refresh the saved device sign-in.")?;
    let BodyContent::RequestSecurityTokenResponse(response) = response.body.body else {
        return Err("Microsoft returned an unsupported device sign-in response.".into());
    };
    let token: Token = (*response).into();
    if !usable_sts(&token, chrono::Utc::now()) { return Err("Microsoft returned an unusable device sign-in token.".into()); }
    tokens.save_device_token(xodus::tokens::manager::PASSPORT_STS.into(), token)
        .map_err(|_| "Could not save the refreshed device sign-in to Keychain.")?;
    Ok(())
}

fn check_socket(path: &Path) -> Outcome<()> {
    let before = match path.symlink_metadata() {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err("Could not inspect the existing Xbox service socket.".into()),
    };
    if !before.file_type().is_socket() || before.uid() != unsafe { nix::libc::geteuid() }
        || before.permissions().mode() & 0o077 != 0 {
        return Err("The Xbox service socket has unexpected ownership, type, or permissions; it was preserved.".into());
    }
    // Only the launcher has the recorded helper identity needed to distinguish
    // its stale socket from a different application's endpoint. It owns recovery.
    Err("An Xbox service socket already exists. Close the game and stop its helper first, or use the launcher to recover its recorded inactive session; this helper never replaces it.".into())
}

fn promote_installation(from: &Path, to: &Path) -> Outcome<()> {
    let from = std::ffi::CString::new(from.as_os_str().as_bytes())?;
    let to = std::ffi::CString::new(to.as_os_str().as_bytes())?;
    // POSIX rename can replace an empty directory created by another process.
    // Darwin's exclusive rename atomically enforces our no-overwrite guarantee.
    #[cfg(target_os = "macos")]
    let result = unsafe { nix::libc::renamex_np(from.as_ptr(), to.as_ptr(), nix::libc::RENAME_EXCL) };
    #[cfg(not(target_os = "macos"))]
    let result = -1;
    if result != 0 { return Err("The completed download could not be moved into place without replacing an existing path.".into()); }
    Ok(())
}

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
    let mut header = [0; 64];
    exe.read_exact(&mut header).await?;
    if &header[..2] != b"MZ" { return Err("The Windows game executable is not prepared.".into()); }
    let offset = u32::from_le_bytes(header[60..64].try_into()?) as u64;
    exe.seek(std::io::SeekFrom::Start(offset)).await?;
    let mut signature = [0; 6];
    exe.read_exact(&mut signature).await?;
    if &signature != b"PE\0\0\x64\x86" || !directory.join("MicrosoftGame.Config").is_file()
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
            required = required.checked_add(info.length).and_then(|size| size.checked_add(4096)).ok_or("Package size overflow.")?;
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
    promote_installation(out, directory)?;
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
    check_socket(Path::new("/tmp/xodus.sock"))?;
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
        .connect_timeout(std::time::Duration::from_secs(30)).timeout(std::time::Duration::from_secs(120)).build()?;
    ensure_device(&client, &tokens).await?;
    if login_needed(&tokens, chrono::Utc::now())? {
        eprintln!("Sign in with the Microsoft account that owns Minecraft: Java & Bedrock for PC.");
        if login::run(&client, &tokens).await != ExitCode::SUCCESS || login_needed(&tokens, chrono::Utc::now())? {
            return Err("Microsoft sign-in was not completed. Run the launcher again to reopen sign-in.".into());
        }
    }
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
    use super::*;
    use xodus::{models::{secrets::{LegacyToken, User}, soap::Timestamp}, tokens::{backend::MemoryBackend, store::TokenBackend}};

    fn fixture_token(expires: &str) -> Token {
        Token::Legacy(LegacyToken {
            key_name: Some(xodus::tokens::PASSPORT_STS.into()), token: "test-only".into(),
            binary_secret: None, tpm_key: None,
            lifetime: Timestamp { id: None, created: "2026-09-30T00:00:00Z".into(), expires: expires.into() },
        })
    }

    fn fixture_time() -> chrono::DateTime<chrono::Utc> {
        chrono::DateTime::parse_from_rfc3339("2026-09-30T00:00:00Z").unwrap().into()
    }

    #[test]
    fn package_paths_cannot_escape_destination() {
        for path in ["", "../file", "C:\\file", "/tmp/file", "dir\\..\\file", "file:stream", "bad\0name"] {
            assert!(safe_relative(path).is_err(), "{path:?}");
        }
        assert_eq!(safe_relative("Installers\\GameInputRedist.msi").unwrap().to_str(), Some("Installers/GameInputRedist.msi"));
    }

    #[test]
    fn restart_reopens_incomplete_login_but_reuses_a_complete_session() {
        let tokens = TokenManager::with_memory();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user(&User { puid: "fixture".into(), username: "fixture".into() }).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-10-01T00:00:00Z")).unwrap();
        assert!(!login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-09-29T00:00:00Z")).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
    }

    #[test]
    fn unusable_sts_is_never_reused() {
        for expiry in ["", "not-a-date", "2026-09-29T00:00:00Z", "2026-09-30T00:00:30Z"] {
            assert!(!usable_sts(&fixture_token(expiry), fixture_time()));
        }
        assert!(!usable_sts(&Token::Compact("fixture".into()), fixture_time()));
        assert!(usable_sts(&fixture_token("2026-10-01T00:00:00Z"), fixture_time()));
    }

    struct DeniedBackend;
    impl TokenBackend for DeniedBackend {
        fn get(&self, _: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied).into())
        }
        fn set(&self, _: &str, _: &[u8]) -> Result<(), TokenStoreError> { panic!("must not overwrite denied credentials"); }
        fn remove(&self, _: &str) -> Result<(), TokenStoreError> { panic!("must not remove denied credentials"); }
    }

    #[tokio::test]
    async fn denied_credentials_do_not_trigger_login_or_device_reprovisioning() {
        let tokens = TokenManager::new(Arc::new(DeniedBackend), Arc::new(MemoryBackend::default()));
        assert!(login_needed(&tokens, fixture_time()).is_err());
        assert!(ensure_device(&reqwest::Client::new(), &tokens).await.is_err());
    }

    #[test]
    fn existing_sockets_and_links_are_preserved_for_launcher_recovery() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("sock");
        assert!(check_socket(&path).is_ok());
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(check_socket(&path).is_err());
        drop(listener);
        assert!(check_socket(&path).is_err());
        assert!(path.exists());
        let link = temporary.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(check_socket(&link).is_err());
        assert!(link.is_symlink());
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn completed_download_cannot_replace_a_racing_destination() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("stage");
        let destination = temporary.path().join("game");
        std::fs::create_dir(&source).unwrap();
        std::fs::write(source.join("fixture"), b"complete").unwrap();
        std::fs::create_dir(&destination).unwrap();
        assert!(promote_installation(&source, &destination).is_err());
        assert!(source.join("fixture").exists());
        assert!(destination.is_dir());
        std::fs::remove_dir(&destination).unwrap();
        promote_installation(&source, &destination).unwrap();
        assert!(!source.exists());
        assert_eq!(std::fs::read(destination.join("fixture")).unwrap(), b"complete");
    }

    #[tokio::test]
    async fn two_byte_mz_placeholder_is_not_a_prepared_game() {
        let temporary = tempfile::tempdir().unwrap();
        std::fs::write(temporary.path().join("Minecraft.Windows.exe"), b"MZ").unwrap();
        std::fs::write(temporary.path().join("MicrosoftGame.Config"), b"fixture").unwrap();
        std::fs::write(temporary.path().join(".xodus-streaming.msixvc"), b"fixture").unwrap();
        assert!(check_game(temporary.path()).await.is_err());
    }
}
