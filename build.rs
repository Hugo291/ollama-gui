fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    // Native-looking widgets: Cupertino on macOS, Fluent elsewhere.
    let style = if target_os == "macos" { "cupertino" } else { "fluent" };
    let config = slint_build::CompilerConfiguration::new()
        .with_style(style.into())
        .with_bundled_translations("lang")
        .with_default_translation_context(slint_build::DefaultTranslationContext::None);
    slint_build::compile_with_config("ui/app.slint", config).expect("Slint build failed");

    // Icon and version information of the Windows executable (needs the Windows
    // resource compiler, so only when building on Windows).
    let host_is_windows = std::env::var("HOST").is_ok_and(|host| host.contains("windows"));
    if target_os == "windows" && host_is_windows {
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon("packaging/windows/app.ico");
        resource.set("FileDescription", "Ollama GUI");
        resource.set("ProductName", "Ollama GUI");
        resource.set("LegalCopyright", "© 2026 Hugo Ferreira. MIT License.");
        resource.compile().expect("Windows resources");
    }
}
