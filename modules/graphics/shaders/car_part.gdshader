shader_type spatial;
// Plain car part (grille, lights, trim) on a Demolition Derby car: crumples
// with the paint (car_deform.gdshaderinc) so lights and grilles stay on the
// bodywork. CarView copies the original material's look into it.

#include "res://modules/graphics/shaders/car_deform.gdshaderinc"

uniform vec4 albedo : source_color = vec4(0.1, 0.1, 0.1, 1.0);
uniform float roughness = 0.5;
uniform float metallic = 0.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
uniform float soot = 0.0;   // blackened by fire

void vertex() {
	apply_crumple(VERTEX, NORMAL);
}

void fragment() {
	ALBEDO = albedo.rgb * (1.0 - 0.7 * soot);
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission * emission_energy;
}
