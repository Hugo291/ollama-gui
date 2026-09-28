//! Networking: the Ollama REST API, registry update checks and the ollama.com library.

pub mod client;
pub mod format;
pub mod library;
pub mod models;
pub mod reference;
pub mod registry;

#[cfg(test)]
mod tests;
