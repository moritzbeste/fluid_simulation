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

layout(set = 0, binding = 4, std430) restrict buffer SubdomainOffset {
    int subdomain_offset[];
} offset;

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
    float grad_spikey_h6_grad2_viscosity_coeff;
    float delta; // time between frames
} meta;


vec3 get_pos(uint index) {
    int idx = int(index) * 2;
    ivec2 tex_size = imageSize(particle_image);
    ivec2 pixel = ivec2(idx % tex_size.x, idx / tex_size.x);
    vec4 data = imageLoad(particle_image, pixel);
    return data.rgb;
}


void main() {
    uint particle_index = gl_GlobalInvocationID.x;
    if (particle_index >= meta.num_particles) return;
    // first compute current sx, sy, sz
    vec3 p = get_pos(particle_index);

    int sx = clamp(int(p.x / meta.box_size_x * meta.subdomain_count_x), 0, meta.subdomain_count_x - 1);
    int sy = clamp(int(p.y / meta.box_size_y * meta.subdomain_count_y), 0, meta.subdomain_count_y - 1);
    int sz = clamp(int(p.z / meta.box_size_z * meta.subdomain_count_z), 0, meta.subdomain_count_z - 1);

    int subdomain = sz * meta.subdomain_count_y * meta.subdomain_count_x 
                  + sy * meta.subdomain_count_x 
                  + sx;
    // atomicAdd prevents race conditions and returns mem before addition but updates the buffer after addition
    // https://registry.khronos.org/OpenGL-Refpages/gl4/html/atomicAdd.xhtml
    int slot = int(atomicAdd(offset.subdomain_offset[subdomain], 1));

    // update
    uint particle_offset = particle_index * meta.ints_per_particle;
    particles_subdomain.data[particle_offset] = sx;
    particles_subdomain.data[particle_offset + 1] = sy;
    particles_subdomain.data[particle_offset + 2] = sz;
    particles_subdomain.data[particle_offset + 3] = subdomain;
    particles_subdomain.data[particle_offset + 4] = slot;
}