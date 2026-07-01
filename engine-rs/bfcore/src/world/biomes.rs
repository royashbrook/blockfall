use super::*;

impl<'c> World<'c> {
    pub(super) fn biome_id(&self) -> i32 {
        worldgen::worldgen_dominant_biome(
            Self::ifloor(self.pos.x),
            Self::ifloor(self.pos.z),
            self.seed,
        )
    }

    pub(super) fn biome_label(&self) -> &'static str {
        if self.block_at(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y) - 1,
            z: Self::ifloor(self.pos.z),
        }) == WATER
        {
            return "Ocean";
        }
        match self.biome_id() {
            1 => "Forest",
            2 => "Mountains",
            3 => "Desert",
            4 => "Snowy",
            5 => "Swamp",
            6 => "Beach",
            _ => "Plains",
        }
    }

    pub(super) fn biome_key(&self) -> &'static str {
        match self.biome_id() {
            1 => "forest",
            2 => "mountains",
            3 => "desert",
            4 => "snowy",
            5 => "swamp",
            6 => "beach",
            _ => "plains",
        }
    }

    pub(super) fn hue_rgb(h: f32) -> V3 {
        let cl = |x: f32| -> f32 {
            if x < 0.0 {
                0.0
            } else if x > 1.0 {
                1.0
            } else {
                x
            }
        };
        let r = (((h * 6.0 + 0.0) % 6.0) - 3.0).abs() - 1.0;
        let g = (((h * 6.0 + 4.0) % 6.0) - 3.0).abs() - 1.0;
        let b = (((h * 6.0 + 2.0) % 6.0) - 3.0).abs() - 1.0;
        V3::new(0.45 + 0.5 * cl(r), 0.45 + 0.5 * cl(g), 0.45 + 0.5 * cl(b))
    }

    pub(super) fn color_for(disp: &str, id: u16) -> V3 {
        let mut h = (id as f32 * 0.6180339) % 1.0;
        if disp == "night_gentle" {
            h = 0.55 + 0.18 * h;
        } else if disp == "boss" {
            h = 0.05 + 0.08 * h;
        } else if disp == "hostile" {
            let base = Self::hue_rgb(0.72 + 0.15 * h);
            return V3::new(base.x * 0.45, base.y * 0.45, base.z * 0.55);
        }
        Self::hue_rgb(h)
    }
}
