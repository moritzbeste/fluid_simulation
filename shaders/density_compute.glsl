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


vec3 get_pos(uint index) {
    int idx = int(index) * 2;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    return data.rgb;
}

void put_den(uint index, float density) {
    int idx = int(index) * 2;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    data.a = density;
    imageStore(particle_image, pixel, data);
}

void put_debug(uint index, float debug) {
    int idx = int(index) * 2 + 1;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    data.a = debug;
    imageStore(particle_image, pixel, data);
}


// poly6 used for density estimation
float poly6_smoothing_kernel(float r_sq) {
    if (r_sq < 0 || r_sq > meta.h_sq) {
        return 0.0;
    }
    float diff = meta.h_sq - r_sq;
    return meta.poly6_coeff * diff * diff * diff;
}


float calc_density(uint particle_index, ivec3 s) {
    vec3 p_i = get_pos(particle_index);
    float density = 0.0;
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
                        vec3 p_j = get_pos(j);
                        float dist_x = p_i.x - p_j.x;
                        float dist_y = p_i.y - p_j.y;
                        float dist_z = p_i.z - p_j.z;
                        float r_sq = dist_x * dist_x + dist_y * dist_y + dist_z * dist_z;
                        density += meta.m * poly6_smoothing_kernel(r_sq);
                    }
                }
            }
        }
    }
    return density;
}


void main() {
    uint particle_index = gl_GlobalInvocationID.x;
    if (particle_index >= meta.num_particles) return;

    uint particle_offset = particle_index * meta.ints_per_particle;
    int sx = particles_subdomain.data[particle_offset];
    int sy = particles_subdomain.data[particle_offset + 1];
    int sz = particles_subdomain.data[particle_offset + 2];
    ivec3 s = ivec3(sx, sy, sz);

    float density = calc_density(particle_index, s);
    put_den(particle_index, density);
}
