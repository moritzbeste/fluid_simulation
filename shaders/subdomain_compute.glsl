#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

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


void main() {
    uint particle_index = gl_GlobalInvocationID.x;
    if (particle_index >= meta.num_particles) return;

    uint particle_offset = particle_index * meta.ints_per_particle;
    int subdomain = particles_subdomain.data[particle_offset + 3];
    int slot = particles_subdomain.data[particle_offset + 4];
    int index = start.subdomain_start[subdomain] + slot;

    subdomains.subdomain[index] = particle_index;
}