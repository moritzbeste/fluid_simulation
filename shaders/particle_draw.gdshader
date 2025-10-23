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
		
		// camera alignment
		// --- Build billboard facing the camera ---
		vec3 camera_forward = normalize(CAMERA_DIRECTION_WORLD);
		vec3 world_up = vec3(0.0, 1.0, 0.0);

		// Reconstruct camera right & up
		vec3 camera_right = normalize(cross(world_up, camera_forward));
		vec3 camera_up = cross(camera_forward, camera_right);

		// Apply the billboard transform
		vec2 quad = (UV - vec2(0.5)) * 2.0; // -> [-1,1] range, center at 0
		vec2 local = quad * radius; 
		VERTEX = pos + camera_right * local.x + camera_up * local.y;
	}

}

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float dist = length(c);
	if (dist > 1.0) discard;

	float border = 0.1; // 0.0 = no outline, 0.1 = thick
	float edge = smoothstep(1.0 - border, 1.0, dist);

	vec3 fill_color = mix(slow_color, fast_color, v_t);
	vec3 outline_color = vec3(0.0); // black outline

	ALBEDO = mix(fill_color, outline_color, edge);
}
