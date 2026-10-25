//! SEDG Manager: one binary that installs the gateway and then manages it.
//!
//! The application is written in Rust and needs no .NET runtime. The PowerShell engine stays the
//! only process that mutates the machine.

pub mod actions;
pub mod broker;
pub mod commands;
pub mod elevate;
pub mod engine;
pub mod http;
pub mod log;
pub mod manifest;
pub mod mode;
pub mod settings;
pub mod setup;
pub mod status;
