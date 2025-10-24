extends Node3D

# management constants
var TESTING : bool = false
var RENDER : bool = false
var POW_PARTICLES : int = 10 if not TESTING else 1
var NUMBER_PARTICLES : int = int(pow(2, POW_PARTICLES))
var FLOATS_PER_PARTICLE : int = 8
var INTS_PER_PARTICLE : int = 5
@warning_ignore("integer_division")
var DISPATCH_SIZE : Vector3i = Vector3i(NUMBER_PARTICLES / 64 if NUMBER_PARTICLES >= 64 else NUMBER_PARTICLES, 1, 1)
var SUBDOMAIN_DIM : Vector3i
var BOX_COEFF : int = 8
var BOX : Vector3i = Vector3i(2 * BOX_COEFF, BOX_COEFF, BOX_COEFF) # box is the domain where particles are confined. one corner is (0, 0, 0) and the other defined here
@warning_ignore("narrowing_conversion")
var TEX : Vector2i = Vector2i(pow(2, int(floor(POW_PARTICLES / 2.0)) + 1), pow(2, int(ceil(POW_PARTICLES / 2.0))))
var NUMBER_SUBDOMAINS : int
var DELTA_OFFSET : int = 88
var MAX_SPEED : float = 10.0
var INIT_VEL_RANGE : float = 10.0
var SLOW_COLOR : Color = Color.WHITE
var FAST_COLOR : Color = Color.RED

var NUM_FRAMES = 1200
var frame_count = 0

# coefficients
var radius : float
var energy_conservation : float
var gravity : float
var mass : float
var rho_0 : float
var mu : float
var k : float
var h : float

# Compute Shader
var rd : RenderingDevice

var shader_rid_histogram : RID
var shader_rid_subdomain : RID
var shader_rid_density : RID
var shader_rid_acceleration : RID

var particles_texture : RID

var subdomain_zeros_packed : PackedByteArray
var particles_subdomain_buffer : RID
var subdomain_buffer : RID
var start_buffer : RID
var offset_buffer : RID
var meta_buffer : RID

var uniform_set_histogram : RID
var uniform_set_subdomain : RID
var uniform_set_density : RID
var uniform_set_acceleration : RID

var pipeline_histogram : RID
var pipeline_subdomain : RID
var pipeline_density : RID
var pipeline_acceleration : RID

var particle_material : ShaderMaterial
var multimesh : MultiMesh
var mm_instance : MultiMeshInstance3D

var img_tex

func _ready():
	assert(TEX.x * TEX.y >= NUMBER_PARTICLES * 2)
	radius = 0.2
	energy_conservation = 0.5
	gravity = 1
	mass = 0.1
	rho_0 = 1.5
	mu = 0.001
	k = 8.14
	h = 0.3
	
	SUBDOMAIN_DIM = Vector3i(int(max(floor(BOX.x / h), 1)), int(max(floor(BOX.y / h), 1)), int(max(floor(BOX.z / h), 1)))
	NUMBER_SUBDOMAINS = SUBDOMAIN_DIM.x * SUBDOMAIN_DIM.y * SUBDOMAIN_DIM.z
	
	rd = RenderingServer.create_local_rendering_device()
	
	# create texture for particle data
	var tex_format : RDTextureFormat = RDTextureFormat.new()
	tex_format.width = TEX.x
	tex_format.height = TEX.y
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var view : RDTextureView = RDTextureView.new() 
	view.format_override = tex_format.format
	
	particles_texture = rd.texture_create(tex_format, view)
	var image : Image = create_particles_texture() if not TESTING else test_particles_texture()
	rd.texture_update(particles_texture, 0, image.get_data())
	
	# create buffers
	var particles_subdomain_packed : PackedByteArray = pack_zeros(NUMBER_PARTICLES * INTS_PER_PARTICLE)
	particles_subdomain_buffer = rd.storage_buffer_create(particles_subdomain_packed.size(), particles_subdomain_packed)
	
	var subdomain_packed : PackedByteArray = pack_zeros(NUMBER_PARTICLES)
	subdomain_buffer = rd.storage_buffer_create(subdomain_packed.size(), subdomain_packed)
	
	subdomain_zeros_packed = pack_zeros(NUMBER_SUBDOMAINS)
	start_buffer = rd.storage_buffer_create(subdomain_zeros_packed.size(), subdomain_zeros_packed)
	
	offset_buffer = rd.storage_buffer_create(subdomain_zeros_packed.size(), subdomain_zeros_packed)
	
	var meta_packed : PackedByteArray = pack_meta()
	meta_buffer = rd.storage_buffer_create(meta_packed.size(), meta_packed)
	
	# create shader RIDs
	shader_rid_histogram = open_shader("res://shaders/histogram_compute.glsl")
	shader_rid_subdomain = open_shader("res://shaders/subdomain_compute.glsl")
	shader_rid_density = open_shader("res://shaders/density_compute.glsl")
	shader_rid_acceleration = open_shader("res://shaders/acceleration_compute.glsl")
	
	# create uniforms
	var uniform_particles_tex : RDUniform = create_uniform(0, particles_texture, RenderingDevice.UNIFORM_TYPE_IMAGE)
	var uniform_particles_subdomain : RDUniform = create_uniform(1, particles_subdomain_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	var uniform_subdomain : RDUniform = create_uniform(2, subdomain_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	var uniform_start : RDUniform = create_uniform(3, start_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	var uniform_offset : RDUniform = create_uniform(4, offset_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	var uniform_meta : RDUniform = create_uniform(5, meta_buffer, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
	
	# create uniform sets
	uniform_set_histogram = rd.uniform_set_create([uniform_particles_tex, uniform_particles_subdomain, uniform_offset, uniform_meta], shader_rid_histogram, 0)
	uniform_set_subdomain = rd.uniform_set_create([uniform_particles_subdomain, uniform_subdomain, uniform_start, uniform_meta], shader_rid_subdomain, 0)
	uniform_set_density = rd.uniform_set_create([uniform_particles_tex, uniform_particles_subdomain, uniform_subdomain, uniform_start, uniform_meta], shader_rid_density, 0)
	uniform_set_acceleration = rd.uniform_set_create([uniform_particles_tex, uniform_particles_subdomain, uniform_subdomain, uniform_start, uniform_meta], shader_rid_acceleration, 0)
	
	pipeline_histogram = rd.compute_pipeline_create(shader_rid_histogram)
	pipeline_subdomain = rd.compute_pipeline_create(shader_rid_subdomain)
	pipeline_density = rd.compute_pipeline_create(shader_rid_density)
	pipeline_acceleration = rd.compute_pipeline_create(shader_rid_acceleration)
	
	# Camera
	var cam := Camera3D.new()
	add_child(cam)
	var box_center = BOX / 2.0
	cam.position = box_center + Vector3(0, 0, BOX.length() * 0.55)
	cam.look_at(box_center, Vector3.UP)
	cam.current = true
	cam.near = 0.1
	cam.far = 100
	print(cam.basis)
	
	var box_instance = create_wireframe_box(BOX)
	add_child(box_instance)
	
	# Base quad mesh
	var quad : QuadMesh = QuadMesh.new()
	quad.size = Vector2(radius * 2, radius * 2)
	
	img_tex = ImageTexture.new()
	img_tex.create_from_image(image)
	
	# Shader material
	particle_material = ShaderMaterial.new()
	particle_material.shader = load("res://shaders/particle_draw.gdshader")
	particle_material.set_shader_parameter("particles_tex", img_tex)
	particle_material.set_shader_parameter("radius", radius)
	particle_material.set_shader_parameter("num_particles", NUMBER_PARTICLES)
	particle_material.set_shader_parameter("slow_color", SLOW_COLOR)
	particle_material.set_shader_parameter("fast_color", FAST_COLOR)
	quad.material = particle_material
	
	# MultiMesh setup
	multimesh = MultiMesh.new()
	multimesh.mesh = quad
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.instance_count = NUMBER_PARTICLES
	
	# MultiMeshInstance3D
	mm_instance = MultiMeshInstance3D.new()
	mm_instance.multimesh = multimesh
	mm_instance.material_override = particle_material
	add_child(mm_instance)
	
	for i in range(NUMBER_PARTICLES):
		multimesh.set_instance_transform(i, Transform3D.IDENTITY)
	return


func _process(delta : float) -> void:
	update_delta(delta)
	
	var cl = rd.compute_list_begin()
	shader_dispatch(cl, pipeline_histogram, uniform_set_histogram)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	prefix_sum()
	
	cl = rd.compute_list_begin()
	shader_dispatch(cl, pipeline_subdomain, uniform_set_subdomain)
	shader_dispatch(cl, pipeline_density, uniform_set_density)
	shader_dispatch(cl, pipeline_acceleration, uniform_set_acceleration)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
	if TESTING: print_buffer(particles_texture, true, true)
	
	# TODO This is slow
	var tex_bytes : PackedByteArray = rd.texture_get_data(particles_texture, 0)
	var read_img := Image.create_from_data(TEX.x, TEX.y, false, Image.FORMAT_RGBAF, tex_bytes)
	img_tex = ImageTexture.create_from_image(read_img)
	particle_material.set_shader_parameter("particles_tex", img_tex)
	
	if RENDER:
		var img = get_viewport().get_texture().get_image()
		img.save_png("../frames/frame_%04d.png" % frame_count)
		assert(frame_count < NUM_FRAMES)
		frame_count += 1
	return


func _exit_tree() -> void:
	# free buffers
	if rd and particles_texture.is_valid():
		rd.free_rid(particles_texture)
	if rd and particles_subdomain_buffer.is_valid():
		rd.free_rid(particles_subdomain_buffer)
	if rd and subdomain_buffer.is_valid():
		rd.free_rid(subdomain_buffer)
	if rd and start_buffer.is_valid():
		rd.free_rid(start_buffer)
	if rd and offset_buffer.is_valid():
		rd.free_rid(offset_buffer)
	if rd and meta_buffer.is_valid():
		rd.free_rid(meta_buffer)
	
	# free uniform sets
	if rd and uniform_set_histogram.is_valid():
		rd.free_rid(uniform_set_histogram)
	if rd and uniform_set_subdomain.is_valid():
		rd.free_rid(uniform_set_subdomain)
	if rd and uniform_set_density.is_valid():
		rd.free_rid(uniform_set_density)
	if rd and uniform_set_acceleration.is_valid():
		rd.free_rid(uniform_set_acceleration)
	
	# free pipelines
	if rd and pipeline_histogram.is_valid():
		rd.free_rid(pipeline_histogram)
	if rd and pipeline_subdomain.is_valid():
		rd.free_rid(pipeline_subdomain)
	if rd and pipeline_density.is_valid():
		rd.free_rid(pipeline_density)
	if rd and pipeline_acceleration.is_valid():
		rd.free_rid(pipeline_acceleration)
	
	# free shaders
	if rd and shader_rid_histogram.is_valid():
		rd.free_rid(shader_rid_histogram)
	if rd and shader_rid_subdomain.is_valid():
		rd.free_rid(shader_rid_subdomain)
	if rd and shader_rid_density.is_valid():
		rd.free_rid(shader_rid_density)
	if rd and shader_rid_acceleration.is_valid():
		rd.free_rid(shader_rid_acceleration)
	return


func update_delta(delta : float) -> void:
	var tmp := StreamPeerBuffer.new()
	tmp.resize(4)
	tmp.put_float(delta)
	rd.buffer_update(meta_buffer, DELTA_OFFSET, 4, tmp.data_array)
	return


func prefix_sum() -> void:
	var writer : StreamPeerBuffer = StreamPeerBuffer.new()
	var size : int = NUMBER_SUBDOMAINS * 4
	writer.resize(size)
	var count : int = 0
	
	var offset_bytes : PackedByteArray = rd.buffer_get_data(offset_buffer)
	var reader : StreamPeerBuffer = StreamPeerBuffer.new()
	reader.data_array = offset_bytes
	
	for i in range(NUMBER_SUBDOMAINS):
		writer.put_32(count)
		count += reader.get_32()
	
	rd.buffer_update(start_buffer, 0, size, writer.data_array)
	rd.buffer_clear(offset_buffer, 0, size)
	return


func print_buffer(buffer : RID, tex : bool, floats : bool) -> void: 
	var bytes = rd.buffer_get_data(buffer) if not tex else rd.texture_get_data(buffer, 0)
	#print("bytes: ", bytes)
	var reader = StreamPeerBuffer.new()
	reader.data_array = bytes
	var list = []
	for i in range(0, len(bytes), 4):
		reader.seek(i)
		if floats:
			list.append(reader.get_float())
		else:
			list.append(reader.get_32())
	print(list)
	return


func shader_dispatch(cl : int, pipeline : RID, uniform_set : RID) -> void:
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, DISPATCH_SIZE.x, DISPATCH_SIZE.y, DISPATCH_SIZE.z)
	return


func create_uniform(binding : int, buffer : RID, uniform_type) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = uniform_type
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func test_particles_texture() -> Image:
	var image : Image = Image.create(TEX.x, TEX.y, false, Image.FORMAT_RGBAF) 
	
	for i in range(NUMBER_PARTICLES):
		var pos : Vector3
		var vel : Vector3
		vel = Vector3(0.0, 0.0, 0.0)
		#pos = Vector3(BOX.x / 2.0, radius * (2 * i + 1), BOX.z / 2.0)
		pos = Vector3(BOX.x / 2.0 + radius * (2 * i + 1), radius, BOX.z / 2.0)
		#pos = Vector3(BOX.x / 2.0 + radius * ((2 * (i % 3)) + 1), radius * ((2 * (i / 9)) + 1), radius * (2 * ((i / 3) % 3) + 1))
		var den = 0.0
		var t = 0.0
		
		var pos_den = Color(pos.x, pos.y, pos.z, den)
		var vel_t = Color(vel.x, vel.y, vel.z, t)
		
		# two pixels per particle
		var index0 : int = i * 2
		var x0 : int = index0 % TEX.x
		@warning_ignore("integer_division")
		var y0 : int = index0 / TEX.x
		image.set_pixel(x0, y0, pos_den)
		
		var index1 : int = index0 + 1
		var x1 : int = index1 % TEX.x
		@warning_ignore("integer_division")
		var y1 : int = index1 / TEX.x
		image.set_pixel(x1, y1, vel_t)
	return image


func create_particles_texture() -> Image:
	var image : Image = Image.create(TEX.x, TEX.y, false, Image.FORMAT_RGBAF) 
	
	for i in range(NUMBER_PARTICLES):
		var pos : Vector3
		var vel : Vector3
		vel = Vector3(0.0, 0.0, 0.0)
		@warning_ignore("integer_division")
		if i < int(NUMBER_PARTICLES / 2):
			@warning_ignore("integer_division")
			pos = Vector3(randf_range(radius, BOX.x / 5.0), randf_range(4 * BOX.y / 5.0, BOX.y - radius), randf_range(radius, float(BOX.z)))
		else:
			@warning_ignore("integer_division")
			pos = Vector3(randf_range(4 * BOX.x / 5.0, BOX.x - radius), randf_range(4 * BOX.y / 5.0, BOX.y - radius), randf_range(radius, float(BOX.z)))
		var den = 0.0
		var t = 0.0
		
		var pos_den = Color(pos.x, pos.y, pos.z, den)
		var vel_t = Color(vel.x, vel.y, vel.z, t)
		
		# two pixels per particle
		var index0 : int = i * 2
		var x0 : int = index0 % TEX.x
		@warning_ignore("integer_division")
		var y0 : int = index0 / TEX.x
		image.set_pixel(x0, y0, pos_den)
		
		var index1 : int = index0 + 1
		var x1 : int = index1 % TEX.x
		@warning_ignore("integer_division")
		var y1 : int = index1 / TEX.x
		image.set_pixel(x1, y1, vel_t)
	return image


func pack_meta() -> PackedByteArray:
	var writer = StreamPeerBuffer.new()
	writer.resize(23 * 4)
	
	writer.put_32(FLOATS_PER_PARTICLE)
	writer.put_32(INTS_PER_PARTICLE)
	writer.put_32(NUMBER_PARTICLES)
	writer.put_32(BOX.x)
	writer.put_32(BOX.y)
	writer.put_32(BOX.z)
	writer.put_32(SUBDOMAIN_DIM.x)
	writer.put_32(SUBDOMAIN_DIM.y)
	writer.put_32(SUBDOMAIN_DIM.z)
	writer.put_float(radius)
	writer.put_float(pow(MAX_SPEED, 2))
	writer.put_float(-energy_conservation) # energy conservation coefficient (negative to flip velocity)
	writer.put_float(gravity) # gravity
	writer.put_float(mass) # particle mass
	writer.put_float(rho_0) # rho_0 : reference density
	writer.put_float(mu) # mu : viscosity coefficient
	writer.put_float(k) # k : gas constant
	writer.put_float(h) # h
	writer.put_float(pow(h, 2)) # h^2
	writer.put_float(2 * pow(h, 3)) # 2 * h^3
	writer.put_float(315 / (64 * PI * pow(h, 9))) # poly6 coefficient : 315 / (64 * pi * h^9)
	writer.put_float(45 / (PI * pow(h, 6))) # gradient spikey coefficient h6 and grad2 viscosity coeff : 45 / (pi * h^6)
	writer.put_float(0.0) # delta
	
	return writer.data_array


func pack_zeros(size : int) -> PackedByteArray:
	var zeros = PackedByteArray()
	zeros.resize(size * 4)
	return zeros


func open_shader(path : String) -> RID:
	var shader_file = load(path)
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	return rd.shader_create_from_spirv(shader_spirv)


func create_wireframe_box(size: Vector3) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	
	var verts = [
		Vector3(0, 0, 0), Vector3(size.x, 0, 0),
		Vector3(size.x, 0, 0), Vector3(size.x, size.y, 0),
		Vector3(size.x, size.y, 0), Vector3(0, size.y, 0),
		Vector3(0, size.y, 0), Vector3(0, 0, 0),
		
		Vector3(0, 0, size.z), Vector3(size.x, 0, size.z),
		Vector3(size.x, 0, size.z), Vector3(size.x, size.y, size.z),
		Vector3(size.x, size.y, size.z), Vector3(0, size.y, size.z),
		Vector3(0, size.y, size.z), Vector3(0, 0, size.z),
		
		Vector3(0, 0, 0), Vector3(0, 0, size.z),
		Vector3(size.x, 0, 0), Vector3(size.x, 0, size.z),
		Vector3(size.x, size.y, 0), Vector3(size.x, size.y, size.z),
		Vector3(0, size.y, 0), Vector3(0, size.y, size.z),
	]
	
	for v in verts:
		im.surface_add_vertex(v)
	
	im.surface_end()
	
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = StandardMaterial3D.new()
	mi.material_override.albedo_color = Color.BLACK
	return mi
