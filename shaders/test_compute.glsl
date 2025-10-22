#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer OutBuf {
    int data[];
} outbuf;

void main() {
    // write a known sentinel into element 0
    outbuf.data[0] = 0x12345678; // 305419896 decimal
}