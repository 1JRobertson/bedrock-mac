//! One stable executable owns sign-in, licensed download, and Xbox IPC.
//! Credentials stay in Keychain. Never log raw service errors or panic payloads.
use std::{collections::{HashMap, HashSet}, path::{Component, Path, PathBuf}, process::ExitCode, sync::{Arc, atomic::{AtomicUsize, Ordering}}};
use std::os::unix::{ffi::OsStrExt, fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt}};
use futures_util::{stream, StreamExt, TryStreamExt};
use msixvc::{streaming, xvd::{SegmentFile, XvdFile}};
use tokio::{fs::{File, OpenOptions}, io::{AsyncReadExt, AsyncSeekExt}};
use xodus::models::secrets::Token;
use xodus::tokens::{TokenManager, store::TokenStoreError};
use xodus::tokens::{backend::{KeychainBackend, MemoryBackend}, store::TokenBackend};
use std::sync::Mutex;

#[path = "../src/webview.rs"] mod webview;
#[path = "../src/commands/login.rs"] mod login;
#[path = "../src/package.rs"] mod package;
#[path = "../src/license.rs"] mod license;

type Outcome<T> = Result<T, Box<dyn std::error::Error>>;
const PRODUCT: &str = "9NBLGGH2JHXJ";

#[derive(Debug)]
struct SetupFailure(&'static str);
impl std::fmt::Display for SetupFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(self.0) }
}
impl std::error::Error for SetupFailure {}
fn failure(code: &'static str) -> Box<dyn std::error::Error> { Box::new(SetupFailure(code)) }

fn package_url_allowed(url: &reqwest::Url) -> bool {
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return false;
    }
    match url.scheme() {
        "https" => true,
        // Microsoft's package catalog returns these HTTP origins. They do not
        // serve certificates for these names; changing the scheme breaks TLS.
        "http" => matches!(url.host_str(), Some("assets1.xboxlive.com" | "assets2.xboxlive.com"))
            && url.port_or_known_default() == Some(80),
        _ => false,
    }
}

fn package_client() -> Outcome<reqwest::Client> {
    // This client carries no sign-in headers or cookies. Authentication and
    // licensing continue to use the separate HTTPS-only account client.
    Ok(reqwest::Client::builder().user_agent("bedrock-mac-standalone/0.1")
        .connect_timeout(std::time::Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 || !package_url_allowed(attempt.url()) {
                attempt.error("Unsupported package redirect")
            } else { attempt.follow() }
        })).build()?)
}

const ACCOUNT_ENTRY: &str = "account-v1";
type AccountValues = HashMap<String, Vec<u8>>;

struct AccountKeychain;
impl TokenBackend for AccountKeychain {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
        KeychainBackend.get(key)
    }
    fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
        #[cfg(target_os = "macos")]
        {
            eprintln!("Keychain: saving sign-in entry ({key}) without rereading it");
            // The legacy keyring setter calls find_generic_password, reading
            // the secret again before every update. SecItemAdd/Update writes
            // directly, without that extra authorization-triggering read.
            security_framework::passwords::set_generic_password(
                "Minecraft Bedrock Standalone", key, value)
                .map_err(|error| std::io::Error::other(format!("Keychain write failed ({})", error.code())))?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        { KeychainBackend.set(key, value) }
    }
    fn remove(&self, key: &str) -> Result<(), TokenStoreError> { KeychainBackend.remove(key) }
}

/// One Keychain read per process instead of one per token. Do not
/// read legacy entries automatically: that itself triggers several prompts.
/// The first run signs in again; previous entries remain untouched.
struct AccountBackend<B> {
    backing: B,
    values: Mutex<Option<AccountValues>>,
}

impl<B: TokenBackend> AccountBackend<B> {
    fn new(backing: B) -> Self { Self { backing, values: Mutex::new(None) } }

    fn load(&self, values: &mut Option<AccountValues>) -> Result<(), TokenStoreError> {
        if values.is_some() { return Ok(()); }
        let loaded = if let Some(bytes) = self.backing.get(ACCOUNT_ENTRY)? {
            serde_json::from_slice(&bytes)?
        } else { AccountValues::new() };
        *values = Some(loaded);
        Ok(())
    }

    fn sign_out(&self) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        next.remove("user-DA");
        next.remove("user-tokens");
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Option<AccountValues>>, TokenStoreError> {
        self.values.lock().map_err(|_| std::io::Error::other("Account cache unavailable").into())
    }
}

impl<B: TokenBackend> TokenBackend for AccountBackend<B> {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        Ok(values.as_ref().and_then(|items| items.get(key).cloned()))
    }

    fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        if next.get(key).is_some_and(|old| old == value) { return Ok(()); }
        next.insert(key.into(), value.to_vec());
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }

    fn remove(&self, key: &str) -> Result<(), TokenStoreError> {
        let mut values = self.lock()?;
        self.load(&mut values)?;
        let mut next = values.as_ref().cloned().unwrap_or_default();
        next.remove(key);
        // Keep even an empty vault so old entries are never resurrected.
        self.backing.set(ACCOUNT_ENTRY, &serde_json::to_vec(&next)?)?;
        *values = Some(next);
        Ok(())
    }
}

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
        Err(_) => return Err(failure("keychain_access")),
    };
    let token_usable = match tokens.get_user_sts_token() {
        Ok(token) => usable_sts(&token, now),
        Err(TokenStoreError::NotFound) => false,
        Err(_) => return Err(failure("keychain_access")),
    };
    Ok(!profile_present || !token_usable)
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

async fn download(client: &reqwest::Client, tokens: &TokenManager, directory: &Path, market: &str, check_only: bool) -> Outcome<()> {
    if directory.symlink_metadata().is_ok() {
        return Err("The download destination must not exist; existing games are never overwritten.".into());
    }
    let parent = directory.parent().ok_or("A destination parent directory is required.")?;
    std::fs::create_dir_all(parent)?;
    let staging = tempfile::Builder::new().prefix(".bedrock-download-").tempdir_in(parent)?;
    let out = staging.path();
    eprintln!("Finding the Windows package for the signed-in owner's Minecraft purchase.");
    let content_id = package::get_content_id(client, PRODUCT.into(), Some(market.into())).await
        .map_err(|_| failure("catalog_lookup"))?;
    let details = package::get_packages(client, tokens, content_id).await
        .map_err(|_| failure("account_package"))?;
    let packages: Vec<_> = details.package_files.iter().filter(|p| p.file_name.ends_with(".msixvc")).collect();
    if packages.len() != 1 { return Err(failure("package_selection")); }
    let package = packages[0];
    let download_client = package_client()?;
    let mut connected = None;
    for cdn in &package.cdn_root_paths {
        let url = format!("{}{}", cdn, package.relative_url);
        if !reqwest::Url::parse(&url).is_ok_and(|url| package_url_allowed(&url)) { continue; }
        match streaming::HttpRead::open(download_client.clone(), &url, None::<fn(u64, u64)>).await {
            Ok(http) => { connected = Some((url, http)); break; },
            Err(error) => {
                // Record only transport categories, never signed URLs or responses.
                eprintln!("Package transport: {:?}", error.kind());
                if let Some(http) = error.get_ref().and_then(|e| e.downcast_ref::<reqwest::Error>()) {
                    eprintln!("Package transport: status={:?}, connect={}, timeout={}",
                        http.status().map(|s| s.as_u16()), http.is_connect(), http.is_timeout());
                    let mut source = std::error::Error::source(http);
                    while let Some(cause) = source {
                        let text = cause.to_string().to_lowercase();
                        for category in ["certificate", "dns", "connection refused", "handshake", "network is unreachable"] {
                            if text.contains(category) { eprintln!("Package transport category: {category}"); }
                        }
                        source = cause.source();
                    }
                }
            },
        }
    }
    let (url, http) = connected.ok_or_else(|| failure("package_connection"))?;
    if package.file_size <= 0 || http.len() != package.file_size as u64 {
        return Err(failure("package_size"));
    }
    let mut metadata = streaming::PrefixCacheFile::new(http, package.file_size as u64, out.join(".xodus-streaming.msixvc")).await
        .map_err(|_| failure("package_cache"))?;
    let xvd = XvdFile::parse(&mut metadata).await.map_err(|_| failure("package_format"))?;
    let mut files: HashMap<String, SegmentFile> = HashMap::new();
    for (name, segment) in xvd.parse_user_package_files(&mut metadata).await.map_err(|_| failure("package_files"))? {
        if name == "SegmentMetadata.bin" { files.extend(xvd.parse_segment_metadata(&mut metadata, &segment).await.map_err(|_| failure("package_segments"))?); }
    }
    files.extend(xvd.parse_ntfs_segment_metadata(&mut metadata, !files.is_empty()).await.map_err(|_| failure("package_filesystem"))?);
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
        .map_err(|_| failure("content_license"))?;
    if owned_license.content_keys.len() != 1 { return Err("Microsoft returned an unsupported content license.".into()); }
    let content_key = owned_license.content_keys.into_values().next().ok_or("Content key missing.")?;
    let key = content_key.unpack(&device_key).map_err(|_| "Could not open the owner's content license.")?;
    if check_only {
        eprintln!("Minecraft download checks passed.");
        return Ok(());
    }
    eprintln!("Downloading Minecraft {} ({} files).", details.version, files.len());
    let completed = AtomicUsize::new(0);
    let total = files.len();
    stream::iter(files.iter()).map(|(name, info)| {
        let xvd = &xvd;
        let key = &key;
        let url = &url;
        let download_client = &download_client;
        let completed = &completed;
        async move {
            let relative = safe_relative(name)?;
            let target = out.join(&relative);
            std::fs::create_dir_all(target.parent().ok_or("Missing output parent.")?)?;
            let mut output = OpenOptions::new().write(true).create_new(true).open(&target).await?;
            tokio::time::timeout(std::time::Duration::from_secs(900),
                xvd.download_file_http(download_client, url, &mut output, info, **key, |_, _| {})).await
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

async fn ensure_device(client: &reqwest::Client, tokens: &TokenManager) -> Outcome<()> {
    use xodus::{hardware, licensing::{splicense::SPLicense, utils::{generate_string, parse_bcrypt_rsa_private}},
        models::{devicecredential::{Authentication, ClientInfo, DeviceAddRequest, DeviceInfo}, secrets::Device, soap::BodyContent}};
    let license = match tokens.get_device_license() {
        Ok(license) => license,
        Err(TokenStoreError::NotFound) => {
            let username = format!("02{}", generate_string(14));
            let password = generate_string(20);
            let provision = DeviceAddRequest {
                client_info: ClientInfo::default(),
                authentication: Authentication::new(username.clone(), password.clone()),
                device_info: Some(DeviceInfo {
                    id: "DeviceInfo".into(), components: hardware::probe_provision_components(), tpm_info: None,
                }),
            };
            let dev = xodus::api::live::login_device_credential(client, provision).await
                .map_err(|_| failure("device_auth"))?;
            let license = Device { username, password, puid: dev.puid, hwid: dev.hw_device_id,
                device_id: dev.license.binding.device_id.unwrap_or_default(), splicense: dev.license.splicense_block };
            tokens.save_device_license(&license).map_err(|_| failure("keychain_access"))?;
            license
        },
        Err(_) => return Err(failure("keychain_access")),
    };
    match tokens.get_device_sts_token() {
        Ok(token) if usable_sts(&token, chrono::Utc::now()) => return Ok(()),
        Ok(_) | Err(TokenStoreError::NotFound) => {},
        Err(_) => return Err(failure("keychain_access")),
    }
    let license_data = SPLicense::parse_base64(&license.splicense).map_err(|_| failure("device_auth"))?;
    let state = license_data.clep_sign_state.ok_or_else(|| failure("device_auth"))?;
    let key = parse_bcrypt_rsa_private(&state.get_rsa_key()).map_err(|_| failure("device_auth"))?;
    let resp = xodus::api::live::authenticate_device(client, license.username, key).await
        .map_err(|_| failure("device_auth"))?;
    let BodyContent::RequestSecurityTokenResponse(resp) = resp.body.body else { return Err(failure("device_auth")); };
    let name = resp.requested_security_token.encrypted_data.as_ref()
        .and_then(|data| data.key_info.key_name.clone()).ok_or_else(|| failure("device_auth"))?;
    let token: Token = (*resp).into();
    if !usable_sts(&token, chrono::Utc::now()) { return Err(failure("device_auth")); }
    tokens.save_device_token(name, token).map_err(|_| failure("keychain_access"))?;
    Ok(())
}

async fn run() -> Outcome<()> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or("Use --download GAME_DIR or --serve GAME_DIR [--market CA].")?;
    if mode == "--help" {
        println!("standalone_helper --download GAME_DIR [--market CA] [--serve-after]\nstandalone_helper --check-download GAME_DIR [--market CA]\nstandalone_helper --serve GAME_DIR [--market CA]\nstandalone_helper --sign-out GAME_DIR\nCredentials: macOS Keychain, Minecraft Bedrock Standalone. Stop any existing Xbox helper first.");
        return Ok(());
    }
    if mode != "--download" && mode != "--check-download" && mode != "--serve" && mode != "--sign-out" { return Err("Unknown helper mode.".into()); }
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
    else if mode != "--sign-out" && directory.symlink_metadata().is_ok() { return Err("Download destination already exists; choose a new directory.".into()); }
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
    let account = Arc::new(AccountBackend::new(AccountKeychain));
    if mode == "--sign-out" {
        account.sign_out().map_err(|_| failure("keychain_access"))?;
        eprintln!("Signed out. Game files and worlds were kept.");
        return Ok(());
    }
    let tokens = Arc::new(TokenManager::new(account, Arc::new(MemoryBackend::default())));
    let client = reqwest::Client::builder().user_agent("bedrock-mac-standalone/0.1").https_only(true)
        .connect_timeout(std::time::Duration::from_secs(30))
        .timeout(std::time::Duration::from_secs(90)).build()?;
    ensure_device(&client, &tokens).await?;
    if login_needed(&tokens, chrono::Utc::now())? {
        eprintln!("Sign in with the Microsoft account that owns Minecraft: Java & Bedrock for PC.");
        if login::run(&client, &tokens).await != ExitCode::SUCCESS { return Err(failure("signin_failed")); }
    }
    if login_needed(&tokens, chrono::Utc::now())? { return Err(failure("signin_cancelled")); }
    if mode == "--download" || mode == "--check-download" {
        // Dropping the download future on cancellation also removes its private
        // temporary directory. Never leave gigabytes of abandoned staging data.
        tokio::select! {
            result = download(&client, &tokens, &directory, &market, mode == "--check-download") => {
                result.map_err(|error| if error.is::<SetupFailure>() { error } else { failure("download_failed") })?;
            },
            _ = tokio::signal::ctrl_c() => return Ok(()),
        }
    } else {
        eprintln!("Verifying this account's Microsoft license for the installed game.");
        authorize_game(&client, &tokens, &directory, &market).await
            .map_err(|_| failure("content_license"))?;
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
    std::panic::set_hook(Box::new(|info| {
        eprintln!("BEDROCK_ERROR:helper_stopped");
        if let Some(location) = info.location() {
            eprintln!("Helper stopped at {}:{}; no account details were logged.", location.file(), location.line());
        }
    }));
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(failure) = error.downcast_ref::<SetupFailure>() {
                eprintln!("BEDROCK_ERROR:{}", failure.0);
            }
            eprintln!("Setup failed: {error}");
            ExitCode::FAILURE
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_out_keeps_device_and_does_not_restore_old_user_tokens() {
        let account = AccountBackend::new(MemoryBackend::default());
        account.set("dev_license", b"device").unwrap();
        account.set("device-tokens", b"device-token").unwrap();
        account.set("user-DA", b"user").unwrap();
        account.set("user-tokens", b"user-token").unwrap();
        account.sign_out().unwrap();
        let reopened = AccountBackend::new(account.backing);
        assert_eq!(reopened.get("dev_license").unwrap().as_deref(), Some(b"device".as_slice()));
        assert_eq!(reopened.get("device-tokens").unwrap().as_deref(), Some(b"device-token".as_slice()));
        assert!(reopened.get("user-DA").unwrap().is_none());
        assert!(reopened.get("user-tokens").unwrap().is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "Creates and removes an isolated Keychain fixture; never reads the user's account"]
    fn native_keychain_updates_preserve_the_latest_value() {
        let key = format!("write-regression-{}", uuid::Uuid::new_v4());
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = security_framework::passwords::delete_generic_password(
                    "Minecraft Bedrock Standalone", &self.0);
            }
        }
        let _cleanup = Cleanup(key.clone());
        for value in [b"fixture-one".as_slice(), b"fixture-two", b"fixture-three"] {
            AccountKeychain.set(&key, value).unwrap();
        }
        let value = security_framework::passwords::get_generic_password(
            "Minecraft Bedrock Standalone", &key).unwrap();
        assert_eq!(value, b"fixture-three");
    }

    #[test]
    fn package_transport_accepts_catalog_origins_without_rewriting_them() {
        for url in ["http://assets1.xboxlive.com/game.msixvc", "http://assets2.xboxlive.com/game.msixvc", "https://example.com/game.msixvc"] {
            let parsed = reqwest::Url::parse(url).unwrap();
            assert!(package_url_allowed(&parsed));
            assert_eq!(parsed.as_str(), url);
        }
        for url in ["http://example.com/game", "http://assets1.xboxlive.com.evil.test/game",
            "http://assets1.xboxlive.com:8080/game", "http://user:secret@assets1.xboxlive.com/game",
            "http://127.0.0.1/game", "file:///tmp/game", "https://example.com/game#fragment"] {
            assert!(!package_url_allowed(&reqwest::Url::parse(url).unwrap()), "{url}");
        }
    }

    #[tokio::test]
    #[ignore = "Live Microsoft CDN check; no account or game download"]
    async fn microsoft_package_transport_connects() {
        let mut reader = streaming::HttpRead::open(package_client().unwrap(),
            "http://assets1.xboxlive.com/Z/routing/up.txt", None::<fn(u64, u64)>).await.unwrap();
        assert_eq!(reader.len(), 2);
        let mut bytes = [0; 2];
        reader.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"UP");
    }

    #[derive(Default)]
    struct TestBackend {
        memory: MemoryBackend,
        reads: Mutex<Vec<String>>,
        fail_key: Mutex<Option<String>>,
        fail_write: std::sync::atomic::AtomicBool,
    }
    impl TokenBackend for TestBackend {
        fn get(&self, key: &str) -> Result<Option<Vec<u8>>, TokenStoreError> {
            self.reads.lock().unwrap().push(key.into());
            if self.fail_key.lock().unwrap().as_deref() == Some(key) {
                return Err(std::io::Error::other("Test read denied").into());
            }
            self.memory.get(key)
        }
        fn set(&self, key: &str, value: &[u8]) -> Result<(), TokenStoreError> {
            if self.fail_write.load(Ordering::Relaxed) { return Err(std::io::Error::other("Test write denied").into()); }
            self.memory.set(key, value)
        }
        fn remove(&self, key: &str) -> Result<(), TokenStoreError> { self.memory.remove(key) }
    }

    #[test]
    fn account_reads_one_entry_per_launch_and_leaves_legacy_entries_alone() {
        let backing = TestBackend::default();
        let keys = ["dev_license", "device-tokens", "user-DA", "user-tokens"];
        for key in keys { backing.memory.set(key, b"legacy").unwrap(); }
        let account = AccountBackend::new(backing);
        for key in keys {
            assert!(account.get(key).unwrap().is_none());
            account.set(key, key.as_bytes()).unwrap();
        }
        assert_eq!(*account.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
        for key in keys { assert_eq!(account.backing.memory.get(key).unwrap().unwrap(), b"legacy"); }
        account.backing.reads.lock().unwrap().clear();
        let reopened = AccountBackend::new(account.backing);
        for key in keys { assert_eq!(reopened.get(key).unwrap().unwrap(), key.as_bytes()); }
        assert_eq!(*reopened.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
    }

    #[test]
    fn denied_account_read_does_not_create_replacement_credentials() {
        let backing = TestBackend::default();
        backing.memory.set("dev_license", b"existing").unwrap();
        *backing.fail_key.lock().unwrap() = Some(ACCOUNT_ENTRY.into());
        let account = AccountBackend::new(backing);
        assert!(account.get("dev_license").is_err());
        assert!(account.backing.memory.get(ACCOUNT_ENTRY).unwrap().is_none());
        assert!(account.values.lock().unwrap().is_none());
    }

    #[test]
    fn failed_write_keeps_cache_and_removed_values_stay_removed() {
        let account = AccountBackend::new(TestBackend::default());
        account.set("user-DA", b"old").unwrap();
        account.backing.fail_write.store(true, Ordering::Relaxed);
        assert!(account.set("user-DA", b"new").is_err());
        assert_eq!(account.get("user-DA").unwrap().unwrap(), b"old");
        account.backing.fail_write.store(false, Ordering::Relaxed);
        account.backing.memory.set("user-DA", b"legacy").unwrap();
        account.remove("user-DA").unwrap();
        let reopened = AccountBackend::new(account.backing);
        assert!(reopened.get("user-DA").unwrap().is_none());
    }

    use xodus::models::{secrets::{LegacyToken, User}, soap::Timestamp};

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
        let account = Arc::new(AccountBackend::new(TestBackend::default()));
        let tokens = TokenManager::new(account.clone(), Arc::new(MemoryBackend::default()));
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user(&User { puid: "fixture".into(), username: "fixture".into() }).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-10-01T00:00:00Z")).unwrap();
        assert!(!login_needed(&tokens, fixture_time()).unwrap());
        tokens.save_user_token(xodus::tokens::PASSPORT_STS.into(), fixture_token("2026-09-29T00:00:00Z")).unwrap();
        assert!(login_needed(&tokens, fixture_time()).unwrap());
        assert_eq!(*account.backing.reads.lock().unwrap(), vec![ACCOUNT_ENTRY]);
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
