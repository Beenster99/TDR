class_name GfxSettings
extends RefCounted
## Graphics settings for the 3D world. Each look can be switched on its own
## (a later options menu can set these before a race starts; WorldView reads
## them when it builds and every frame for the camera).

## Camera
static var fov_deg := 30.0          ## vertical field of view (narrow = flatter, map-like)
static var tilt_deg := 12.0         ## camera tilt off straight-down, 0..30

## Light and shadow
static var sun_shadows := true
static var sun_max_elevation_deg := 30.0   ## low sun (long shadows) reads hills and cars best
static var ssao := true
static var glow := true

## Elevation cues (they only show on tracks with height data)
static var hillshade := 2.0         ## extra shading by slope on grass; 0.6x on the road

## Trackside
static var trees := 1.0             ## tree density, 0 = none
static var grandstands := true
static var buildings := true

## Cars
static var car_detail_distance := 700.0   ## camera distance (m) beyond which small parts hide
