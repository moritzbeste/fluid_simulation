shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D particles_tex;
varying float v_t;

uniform float radius;
uniform int num_particles;
uniform vec3 slow_color;
uniform vec3 fast_color;

void vertex() {
	// Called for every vertex the material is visible on.
	int id = int(INSTANCE_ID);
	if (id >= num_particles) {
		VERTEX += vec3(0.0);
	}
	else {
		int tex_idx_pos = id * 2;
		int tex_idx_vel = tex_idx_pos + 1;
		ivec2 tex_size = textureSize(particles_tex, 0);

		vec2 uv_pos =  (vec2(float(tex_idx_pos % tex_size.x) + 0.5, float(tex_idx_pos / tex_size.x) + 0.5)) / vec2(tex_size);
		vec2 uv_vel =  (vec2(float(tex_idx_vel % tex_size.x) + 0.5, float(tex_idx_vel / tex_size.x) + 0.5)) / vec2(tex_size);

		vec4 texel_pos = texture(particles_tex, uv_pos);
		vec4 texel_vel = texture(particles_tex, uv_vel);

		vec3 pos = texel_pos.rgb;
		v_t = texel_vel.a;

		VERTEX += pos;
	}

}

void fragment() {
	// Called for every pixel the material is visible on.
	vec2 c = UV * 2.0 - 1.0;
	if (dot(c, c) > 1.0) discard;
	ALBEDO = mix(slow_color, fast_color, v_t);
}
