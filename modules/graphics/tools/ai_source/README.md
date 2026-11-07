# AI-generated car bodies

Some cars get their body from a mesh made by an AI image-to-3D model instead
of the lofted cross-sections in `build_cars.py`. The mesh here is the raw
shape, with only the floor it was standing on taken off (and decimated to
about 200k triangles). `ai_body.py` does the rest at build time (scale to
real size on the real axles, cut off the AI's wing and wheels, smooth, glass
and lights, split into parts). Turn it on with an `ai_body` block in the
car's shape file.

| File | Made with | From the photo |
|---|---|---|
| `alpine_a110_s.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Alpine A110 S Automesse Ludwigsburg 2022 1X7A5946" by Alexander Migl, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Alpine_A110_S_Automesse_Ludwigsburg_2022_1X7A5946.jpg |
| `bmw_m2.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "BMW G87 M2 1X7A1838" by Alexander-93, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:BMW_G87_M2_1X7A1838.jpg |
| `bmw_m4_gt3.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "The New BMW M4 GT3" by Arturo Hurtado, CC BY 2.0, https://commons.wikimedia.org/wiki/File:The_New_BMW_M4_GT3.jpg |
| `cadillac_v_series_r.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 6 Hours of Spa-Francorchamps Cadillac Racing Cadillac V-Series.R No.3 (DSC07010)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2023_6_Hours_of_Spa-Francorchamps_Cadillac_Racing_Cadillac_V-Series.R_No.3_(DSC07010).jpg |
| `chevrolet_corvette_z06.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "C8z06 z07" by Duboyong, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:C8z06_z07.jpg |
| `ferrari_296_gt3.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2024 6 Hours of Spa-Francorchamps Vista AF Corse Ferrari 296 GT3 No.55 (DSC02308)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2024_6_Hours_of_Spa-Francorchamps_Vista_AF_Corse_Ferrari_296_GT3_No.55_(DSC02308).jpg |
| `ferrari_499p.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 6 Hours of Spa-Francorchamps Ferrari AF Corse Ferrari 499P No.50 (DSC04894)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2023_6_Hours_of_Spa-Francorchamps_Ferrari_AF_Corse_Ferrari_499P_No.50_(DSC04894).jpg |
| `honda_civic_type_r.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2024 Honda Civic Type R, front right, 06-15-2024" by MercurySable99, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2024_Honda_Civic_Type_R,_front_right,_06-15-2024.jpg |
| `lamborghini_huracan_gt3.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Miguel Ramos, Barwell Motorsport Lamborghini Huracan GT3 Evo, 2019" by Interceptor73, CC BY 2.0, https://commons.wikimedia.org/wiki/File:Miguel_Ramos,_Barwell_Motorsport_Lamborghini_Huracan_GT3_Evo,_2019.jpg |
| `ligier_js_p217_gibson.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Ligier JS P217 (52575006476)" by Alexandre Prevot from Nancy, France, CC BY-SA 2.0, https://commons.wikimedia.org/wiki/File:Ligier_JS_P217_(52575006476).jpg |
| `mazda_mx5_nd.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Mazda MX-5 (ND) 1X7A7471" by Alexander-93, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Mazda_MX-5_(ND)_1X7A7471.jpg |
| `mclaren_720s_gt3.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "McLaren 720S GT3, GIMS 2019, Le Grand-Saconnex (GIMS0559)" by Matti Blume, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:McLaren_720S_GT3,_GIMS_2019,_Le_Grand-Saconnex_(GIMS0559).jpg |
| `mclaren_750s.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 McLaren 750S 1" by Calreyn88, CC0, https://commons.wikimedia.org/wiki/File:2023_McLaren_750S_1.jpg |
| `nissan_gt_r_nismo.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2022 Nissan GT-R Nismo SCD 24" by MrWalkr, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2022_Nissan_GT-R_Nismo_SCD_24.jpg |
| `oreca_07_gibson.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "24 Heures du Mans 2026 LMP2 No. 4 Oreca 07-Gibson CROWDSTRIKE RACING BY APR" by T GOUREAU, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:24_Heures_du_Mans_2026_LMP2_No._4_Oreca_07-Gibson_CROWDSTRIKE_RACING_BY_APR.jpg |
| `peugeot_9x8.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 6 Hours of Spa-Francorchamps Peugeot TotalEnergies Peugeot 9X8 No.93 (DSC05645)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2023_6_Hours_of_Spa-Francorchamps_Peugeot_TotalEnergies_Peugeot_9X8_No.93_(DSC05645).jpg |
| `porsche_718_cayman_gt4_rs.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2022 Porsche Cayman GT4RS" by MrWalkr, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2022_Porsche_Cayman_GT4RS.jpg |
| `porsche_911_gt3_r.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2024 6 Hours of Spa-Francorchamps Manthey PureRxcing Porsche 911 GT3 R No.92 (DSC02798)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2024_6_Hours_of_Spa-Francorchamps_Manthey_PureRxcing_Porsche_911_GT3_R_No.92_(DSC02798).jpg |
| `porsche_963.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2024 6 Hours of Spa-Francorchamps Porsche Penske Motorsport Porsche 963 No.5 (DSC02380)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2024_6_Hours_of_Spa-Francorchamps_Porsche_Penske_Motorsport_Porsche_963_No.5_(DSC02380).jpg |
| `toyota_gr010_hybrid.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 6 Hours of Spa-Francorchamps Toyota Gazoo Racing Toyota GR010 Hybrid No.7 (DSC04418)" by MarcelX42, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2023_6_Hours_of_Spa-Francorchamps_Toyota_Gazoo_Racing_Toyota_GR010_Hybrid_No.7_(DSC04418).jpg |
| `toyota_gr_supra.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2020 Toyota Supra front NYIAS 2019" by Kevauto, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2020_Toyota_Supra_front_NYIAS_2019.jpg |
| `toyota_gr_yaris.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Toyota GR Yaris (XP21) – f 03052021" by M 93, CC BY-SA 3.0 de, https://commons.wikimedia.org/wiki/File:Toyota_GR_Yaris_(XP21)_%E2%80%93_f_03052021.jpg |

Licences: TripoSG (VAST-AI-Research) is MIT licensed, so its output can be
used anywhere. Every car here is made with TripoSG. (The first 911 GT3 R body
was made with Hunyuan3D, whose community licence does not cover the EU, the UK
or South Korea; it was replaced with a TripoSG one.)

Making another one:

1. Pick a freely licensed photo of the car (Wikimedia Commons), three-quarter
   view, the whole car in frame. Note its author and licence in the table.
2. Make the shape with `triposg_cpu.py` (runs on a CPU, about 15 minutes a
   car; see its header for the one-off setup).
3. Keep only the biggest piece and decimate to ~200k triangles (`decimate.py`),
   saved here as `<car_id>.glb`, still in glTF space (Y up).
4. Add `ai_body` to the shape file (see `ai_body.py` for the keys: flip,
   fit_width, height, wheel cuts, glass and light regions) and build the car
   as usual. TripoSG shells usually face backwards (`"flip": true`), but not
   always (the BMW M4 GT3 is `false`): check which end has the grille. They
   come out a little too wide, so use `"fit_width"` and the real `"height"`.
   Things the AI invents above the car (aerials, a second wing, a rotor) go
   with `"pre_cut_z"`; a tow strap that stretches the length goes with
   `"trim"`. Headlights are a dark `light_lens` region with a small
   `light_head` inside it.
