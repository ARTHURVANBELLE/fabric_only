mod cloth_app;

use std::sync::Arc;

use crate::cloth_app::ClothApp;
use wgpu_bootstrap::{egui, Runner};

fn main() {
    let mut runner = Runner::new(
        "Gui App",
        800,
        600,
        egui::Color32::from_rgb(245, 245, 245),
        32,
        0,
        Box::new(|context| Arc::new(ClothApp::new(context))),
    );
    runner.run();
}
