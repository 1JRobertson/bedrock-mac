//! One application owns login, licensed executable preparation, and Xbox IPC.
use std::{path::Path, sync::Arc, process::ExitCode};
use xodus::tokens::{TokenManager, store::TokenStoreError};
#[path = "../src/webview.rs"]
mod webview;
#[path = "../src/commands/login.rs"]
mod login;
#[path = "bedrock_helper_parts/prepare_owned_game.rs"]
mod prepare_owned_game;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = std::env::args().nth(1).ok_or("game directory required")?;
    if Path::new("/tmp/xodus.sock").exists() {
        return Err("An Xbox service socket already exists; stop its owner before starting another helper.".into());
    }
    xodus::secrets::init_named_secrets("Minecraft Bedrock Mac")?;
    let tokens = Arc::new(TokenManager::with_keychain_and_memory());
    let client = reqwest::Client::builder().user_agent("bedrock-mac-helper/0.1").build()?;
    xodus::tokens::device::ensure_device_credentials(&client, &tokens).await;
    let needs_login = match tokens.get_user() {
        Ok(_) => false,
        Err(TokenStoreError::NotFound) => true,
        Err(error) => return Err(error.into()),
    };
    if needs_login {
        eprintln!("Complete Microsoft sign-in in the login window.");
        if login::run(&client, &tokens).await != ExitCode::SUCCESS {
            return Err("Microsoft sign-in was not completed".into());
        }
    }
    tokens.get_user_sts_token()?;
    eprintln!("Microsoft sign-in available. Preparing the owned Windows game.");
    prepare_owned_game::prepare(Path::new(&directory), &client, &tokens).await?;
    eprintln!("Starting Xbox account service.");
    xodus_service::run(tokens).await;
    Ok(())
}
