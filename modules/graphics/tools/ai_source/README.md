# AI-generated car bodies

Some cars get their body from a mesh made by an AI image-to-3D model instead
of the lofted cross-sections in `build_cars.py`. The mesh here is the raw
shape, with only the floor it was standing on taken off. `ai_body.py` does
the rest at build time (scale to real size on the real axles, cut off the
AI's wing and wheels, smooth, glass and lights, split into parts). Turn it on
with an `ai_body` block in the car's shape file.

| File | Made with | From the photo |
|---|---|---|
| `porsche_911_gt3_r.glb` | Hunyuan3D 2.1 (tencent/Hunyuan3D-2.1 on Hugging Face), shape only, 20 steps, seed 1234, octree 320 | "Porsche 911 992 GT3 Cup" by pelican-actor, CC BY 2.0, https://commons.wikimedia.org/wiki/File:Porsche_911_992_GT3_Cup.jpg |

Making another one:

1. Pick a freely licensed photo of the car (Wikimedia Commons), three-quarter
   view, the whole car in frame. Note its author and licence in the table.
2. Run the Hugging Face space's `/shape_generation` endpoint with it
   (`gradio_client`, no texture). The free quota is small, so one try at a time.
3. Remove anything that isn't the car (a floor or plinth) and save it here as
   `<car_id>.glb`, still in glTF space (Y up).
4. Add `ai_body` to the shape file (see `ai_body.py` for the keys: the wing
   cut line, glass and light regions) and build the car as usual.
