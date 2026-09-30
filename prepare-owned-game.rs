//! Materialize encrypted executable segments with the signed-in owner's license.
//! No keys or account tokens are written to disk or stdout.
use std::{collections::HashMap, path::{Path, Component}};
use tokio::{fs::File, io::AsyncReadExt};
use msixvc::xvd::XvdFile;
#[path = "../../src/license.rs"]
mod license;

pub async fn prepare(directory: &Path, client: &reqwest::Client, tokens: &xodus::tokens::TokenManager) -> Result<(), Box<dyn std::error::Error>> {
    let out = directory.canonicalize()?;
    let mut metadata = File::open(out.join(".xodus-streaming.msixvc")).await?;
    let xvd = XvdFile::parse(&mut metadata).await?;
    let mut files = HashMap::new();
    for (name, segment) in xvd.parse_user_package_files(&mut metadata).await? {
        if name == "SegmentMetadata.bin" {
            files.extend(xvd.parse_segment_metadata(&mut metadata, &segment).await?);
        }
    }
    files.extend(xvd.parse_ntfs_segment_metadata(&mut metadata, !files.is_empty()).await?);
    xvd.populate_segment_hashes(&mut files)?;
    let (device_key, content_license) = license::get_license(&client, &tokens, xvd.content_id().to_string(), "CA".into()).await
        .map_err(|_| "license acquisition failed")?;
    if content_license.content_keys.len() != 1 { return Err("expected one content key".into()); }
    let content_key = content_license.content_keys.into_values().next().ok_or("content key absent")?;
    let key = content_key.unpack(&device_key).map_err(|_| "content key unpack failed")?;
    for (name, info) in files {
        if !info.keep_encrypted { continue; }
        let normalized = name.replace('\\', "/");
        let relative = Path::new(&normalized);
        if relative.components().any(|c| !matches!(c, Component::Normal(_))) { return Err("unsafe output path".into()); }
        let target = out.join(relative);
        if !target.parent().ok_or("missing parent")?.canonicalize()?.starts_with(&out) || target.is_symlink() {
            return Err("output path escapes destination".into());
        }
        let mut input = File::open(&target).await?;
        let mut signature = [0; 2];
        input.read_exact(&mut signature).await?;
        if &signature == b"MZ" { println!("Already prepared {normalized}"); continue; }
        drop(input);
        let mut input = File::open(&target).await?;
        let temp = target.with_extension("preparing");
        let mut output = tokio::fs::OpenOptions::new().write(true).create_new(true).open(&temp).await?;
        xvd.mount_mem_fd(&mut input, &mut output, &info, *key, |_, _| {}).await?;
        output.sync_all().await?;
        drop(output);
        let mut check = File::open(&temp).await?;
        check.read_exact(&mut signature).await?;
        if &signature != b"MZ" { return Err("prepared executable has invalid signature".into()); }
        drop(check);
        tokio::fs::rename(&target, target.with_extension("xodus-encrypted")).await?;
        tokio::fs::rename(&temp, &target).await?;
        println!("Prepared {normalized}");
    }
    Ok(())
}
