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
| `porsche_911_gt3_r.glb` | Hunyuan3D 2.1 (tencent/Hunyuan3D-2.1 on Hugging Face), shape only, 20 steps, seed 1234, octree 320 | "Porsche 911 992 GT3 Cup" by pelican-actor, CC BY 2.0, https://commons.wikimedia.org/wiki/File:Porsche_911_992_GT3_Cup.jpg |
| `alpine_a110_s.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Alpine A110 S Automesse Ludwigsburg 2022 1X7A5946" by Alexander Migl, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Alpine_A110_S_Automesse_Ludwigsburg_2022_1X7A5946.jpg |
| `bmw_m2.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "BMW G87 M2 1X7A1838" by Alexander-93, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:BMW_G87_M2_1X7A1838.jpg |
| `chevrolet_corvette_z06.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "C8z06 z07" by Duboyong, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:C8z06_z07.jpg |
| `honda_civic_type_r.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2024 Honda Civic Type R, front right, 06-15-2024" by MercurySable99, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2024_Honda_Civic_Type_R,_front_right,_06-15-2024.jpg |
| `mazda_mx5_nd.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Mazda MX-5 (ND) 1X7A7471" by Alexander-93, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:Mazda_MX-5_(ND)_1X7A7471.jpg |
| `mclaren_750s.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2023 McLaren 750S 1" by Calreyn88, CC0, https://commons.wikimedia.org/wiki/File:2023_McLaren_750S_1.jpg |
| `nissan_gt_r_nismo.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2022 Nissan GT-R Nismo SCD 24" by MrWalkr, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2022_Nissan_GT-R_Nismo_SCD_24.jpg |
| `porsche_718_cayman_gt4_rs.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2022 Porsche Cayman GT4RS" by MrWalkr, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2022_Porsche_Cayman_GT4RS.jpg |
| `toyota_gr_supra.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "2020 Toyota Supra front NYIAS 2019" by Kevauto, CC BY-SA 4.0, https://commons.wikimedia.org/wiki/File:2020_Toyota_Supra_front_NYIAS_2019.jpg |
| `toyota_gr_yaris.glb` | TripoSG (VAST-AI/TripoSG), shape only, 30 steps, seed 42 | "Toyota GR Yaris (XP21) – f 03052021" by M 93, CC BY-SA 3.0 de, https://commons.wikimedia.org/wiki/File:Toyota_GR_Yaris_(XP21)_%E2%80%93_f_03052021.jpg |

Licences: TripoSG (VAST-AI-Research) is MIT licensed, so its output can be
used anywhere. Hunyuan3D's community licence does not cover the EU, the UK or
South Korea, so new cars use TripoSG.

Making another one:

1. Pick a freely licensed photo of the car (Wikimedia Commons), three-quarter
   view, the whole car in frame. Note its author and licence in the table.
2. Make the shape with `triposg_cpu.py` (runs on a CPU, about 15 minutes a
   car; see its header for the one-off setup).
3. Keep only the biggest piece and decimate to ~200k triangles (`decimate.py`),
   saved here as `<car_id>.glb`, still in glTF space (Y up).
4. Add `ai_body` to the shape file (see `ai_body.py` for the keys: flip,
   fit_width, height, wheel cuts, glass and light regions) and build the car
   as usual. TripoSG shells face backwards (`"flip": true`) and come out a
   little too wide, so use `"fit_width": true` and the real `"height"`.
