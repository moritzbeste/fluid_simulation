#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, binding = 0) uniform image2D particle_image;
    // float px
    // float py
    // float pz
    // float density
    // float vx
    // float vy
    // float vz
    // float t

layout(set = 0, binding = 1, std430) restrict buffer Particles_Subdomain {
    int data[];
    // int sx
    // int sy
    // int sz
    // int subdomain
    // int slot
} particles_subdomain;

layout(set = 0, binding = 2, std430) restrict buffer Subdomains {
    uint subdomain[];
    // uint particle_index
} subdomains;

layout(set = 0, binding = 3, std430) restrict buffer SubdomainStart {
    int subdomain_start[];
} start;

layout(set = 0, binding = 5, std430) restrict buffer Meta {
    int floats_per_particle;
    int ints_per_particle;
    int num_particles;
    int box_size_x;
    int box_size_y;
    int box_size_z;
    int subdomain_count_x;
    int subdomain_count_y;
    int subdomain_count_z;
    float rad;
    float max_speed_sq;
    float energy_cons; // energy conservation after bounce (negative)
    float g; // gravity
    float m; // particle mass
    float rho_0; // reference density
    float mu; // viscosity coeff
    float k; // gas constant
    // kernel core radius
    float h;
    float h_sq;
    float two_h_cube;
    // coefficients for smoothing kernels
    float poly6_coeff;
    float grad_spiky_h6_grad2_viscosity_coeff;
    float delta; // time between frames
} meta;


vec4 get_pos_den(uint index) {
    int idx = int(index) * 2;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    return data;
}

vec3 get_vel(uint index) {
    int idx = int(index) * 2 + 1;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    return data.rgb;
}

void put_pos_vel(uint index, vec3 pos, vec3 vel, float t) {
    int idx = int(index) * 2;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    data.rgb = pos;
    imageStore(particle_image, pixel, data);

    idx += 1;
    pixel.x = idx % tex_size.x;
    pixel.y = idx / tex_size.x;
    data = imageLoad(particle_image, pixel);
    data.rgb = vel;
    data.a = t;
    imageStore(particle_image, pixel, data);
}


// spiky used for pressure estimation
vec3 grad_spiky_smoothing_kernel(float dx, float dy, float dz, float r) {
    if (r <= 0.0 || r > meta.h) {
        return vec3(0.0, 0.0, 0.0);
    }
    float diff = meta.h - r;
    float coeff = meta.grad_spiky_h6_grad2_viscosity_coeff * (diff * diff);
    return coeff * vec3(dx, dy, dz); 
}


float grad2_viscosity_smoothing_kernel(float r) {
    return 0.0;
}


vec3 calc_a(uint particle_index, ivec3 s) {
    vec4 p_i = get_pos_den(particle_index);
    float pressure_i = meta.k * -abs(p_i.w - meta.rho_0);

    vec3 f_pressure = vec3(0.0, 0.0, 0.0);
    // find surrounding subdomains
    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dz = -1; dz <= 1; dz++) {
                int nx = s.x + dx;
                int ny = s.y + dy;
                int nz = s.z + dz;
                // check if this is a valid subdomain
                if (nx >= 0 && nx < meta.subdomain_count_x && ny >= 0 && ny < meta.subdomain_count_y && nz >= 0 && nz < meta.subdomain_count_z) {
                    // valid subdomain
                    int subdomain = nz * meta.subdomain_count_y * meta.subdomain_count_x + ny * meta.subdomain_count_x + nx;
                    int end;
                    if (subdomain + 1 < meta.subdomain_count_x * meta.subdomain_count_y * meta.subdomain_count_z) end = start.subdomain_start[subdomain + 1];
                    else end = meta.num_particles;
                    for (int i = start.subdomain_start[subdomain]; i < end; i++) {
                        uint j = subdomains.subdomain[i];
                        vec4 p_j = get_pos_den(j);
                        float dist_x = p_i.x - p_j.x;
                        float dist_y = p_i.y - p_j.y;
                        float dist_z = p_i.z - p_j.z;
                        float r_sq = dist_x * dist_x + dist_y * dist_y + dist_z * dist_z;
                        float r = sqrt(r_sq);
                        // pressure
                        float pressure_j = meta.k * -abs(p_j.w - meta.rho_0);
                        f_pressure -= meta.m * (pressure_i + pressure_j) / (2 * p_j.w) * grad_spiky_smoothing_kernel(dist_x, dist_y, dist_z, r);
                    }
                }
            }
        }
    }
    return (f_pressure + vec3(0.0, p_i.w * -meta.g, 0.0)) / p_i.w;
}


void main() {
    uint particle_index = gl_GlobalInvocationID.x;
    if (particle_index >= meta.num_particles) return;

    // bounce logic before velocity update to avoid sticking
    vec3 p = get_pos_den(particle_index).rgb;
    vec3 v = get_vel(particle_index);

    uint particle_offset = particle_index * meta.ints_per_particle;
    int sx = particles_subdomain.data[particle_offset];
    int sy = particles_subdomain.data[particle_offset + 1];
    int sz = particles_subdomain.data[particle_offset + 2];
    ivec3 s = ivec3(sx, sy, sz);

    if (p.x - meta.rad < 0) {
        p.x = meta.rad;
        v.x *= meta.energy_cons;
    }
    else if (p.x + meta.rad > meta.box_size_x) {
        p.x = meta.box_size_x - meta.rad;
        v.x *= meta.energy_cons;
    }
    if (p.y - meta.rad < 0) {
        p.y = meta.rad;
        v.y *= meta.energy_cons;
    }
    else if (p.y + meta.rad > meta.box_size_y) {
        p.y = meta.box_size_y - meta.rad;
        v.y *= meta.energy_cons;
    }
    if (p.z - meta.rad < 0) {
        p.z = meta.rad;
        v.z *= meta.energy_cons;
    }
    else if (p.z + meta.rad > meta.box_size_z) {
        p.z = meta.box_size_z - meta.rad;
        v.z *= meta.energy_cons;
    }

    vec3 acceleration = calc_a(particle_index, s) * 1/120.0;
    v += vec3(acceleration.x, acceleration.y, acceleration.z);
    p += vec3(v.x * 1/120.0, v.y * 1/120.0, v.z * 1/120.0);
    float speed_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    float t = clamp(speed_sq / meta.max_speed_sq, 0.0, 1.0);

    put_pos_vel(particle_index, p, v, t);
}