mod instances_app;

use std::sync::Arc;

use crate::instances_app::InstanceApp;
use wgpu_bootstrap::{egui, Runner};

fn main() {
    let mut runner = Runner::new(
        "Fabric Simulation",
        800,
        600,
        egui::Color32::from_rgb(255, 206, 27),
        32,
        0,
        Box::new(|context| Arc::new(InstanceApp::new(context))),
    );
    runner.run();
}
