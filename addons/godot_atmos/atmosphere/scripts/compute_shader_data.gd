class_name ComputeShaderData
extends RefCounted

var output_texture_rd: Texture
var output_texture: RID
var compute_shader: RID
var uniform_set: RID
var pipeline: RID
var storage_buffer: RID
var transmittance_lut_sampler = null

# Main shader path
const shader_file_path = "addons/godot_atmos/atmosphere/shaders/atmosphere.txt"

# Include paths
const common_include_shader_file_path = "addons/godot_atmos/atmosphere/shaders/common.txt"
const shading_include_shader_file_path = "addons/godot_atmos/atmosphere/shaders/shading.txt"
const uniforms_include_shader_file_path = "addons/godot_atmos/atmosphere/shaders/uniforms.txt"
const uniform_transmittance_include_shader_file_path = "addons/godot_atmos/atmosphere/shaders/uniform_transmittance.txt"

# LUT shaders paths
const transmittance_lut_shader_file_path = "addons/godot_atmos/atmosphere/shaders/transmittance.txt"
const aerial_perspective_lut_shader_file_path = "addons/godot_atmos/atmosphere/shaders/aerial_perspective.txt"
const sky_view_lut_shader_file_path = "addons/godot_atmos/atmosphere/shaders/sky_view.txt"

func render_process(rendering_device: RenderingDevice, camera_height, angle, width, height, depth):
	var compute_list := rendering_device.compute_list_begin()
	rendering_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rendering_device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	var push_constant_buffer = PackedFloat32Array()
	push_constant_buffer.push_back(camera_height)
	push_constant_buffer.push_back(angle)
	push_constant_buffer.push_back(0)
	push_constant_buffer.push_back(0)
	rendering_device.compute_list_set_push_constant(compute_list, push_constant_buffer.to_byte_array(), push_constant_buffer.size() * 4)

	rendering_device.compute_list_dispatch(compute_list, width, height, depth)
	rendering_device.compute_list_end()

func process():
	set_output_texture_rd_rids()

func set_output_texture_rd_rids():
	# Update our texture2d to show our next result (we are about to create).
	# Note that `_initialize_compute_code` may not have run yet so the first
	# frame this my be an empty RID.
	if output_texture_rd is Texture2DRD:
		output_texture_rd.texture_rd_rid = output_texture
	elif output_texture_rd is Texture3DRD:
		output_texture_rd.texture_rd_rid = output_texture


func clear_rids(rendering_device: RenderingDevice) -> void:
	print('free: uniform set')
	rendering_device.free_rid(uniform_set)
	print('free: pipeline')
	rendering_device.free_rid(pipeline)
	print('free: compute shader')
	rendering_device.free_rid(compute_shader) # This, apparently, should be last
	# Free RIDs when leaving the tree...
	if output_texture_rd is Texture2DRD:
		output_texture_rd.texture_rd_rid = RID()
	elif output_texture_rd is Texture3DRD:
		output_texture_rd.texture_rd_rid = RID()
	print('free: output_texture')
	rendering_device.free_rid(output_texture)
	print('free: storage buffer')
	rendering_device.free_rid(storage_buffer)
	if transmittance_lut_sampler != null:
		print('free: transmittance lut sampler')
		rendering_device.free_rid(transmittance_lut_sampler)

func read_text_file(path: String):
	var file = FileAccess.open("res://" + path, FileAccess.READ)
	return file.get_as_text()

# Creates and returns a RGBA_f32 texture2d/texture3e for compute shaders
# Use im_depth > 1 for 3d textures.
func make_compute_texture(rendering_device: RenderingDevice, im_width: int, im_height: int, im_depth: int = 1, binding: int = 0):
	# Format section
	var format = RDTextureFormat.new()
	format.width = im_width
	format.height = im_height
	format.depth = im_depth
	if im_depth == 1:
		format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	else:
		format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

	# View section
	var view := RDTextureView.new()

	# Image section
	var output_tex: RID
	var output_tex_uniform: RDUniform
	if im_depth == 1:
		var output_image := Image.create(im_width, im_height, false, Image.FORMAT_RGBAF)
		output_tex = rendering_device.texture_create(format, view, [output_image.get_data()])
		output_tex_uniform = make_uniform_from_texture(output_tex, binding)
	else:
		# image_height * im_depth as per: https://github.com/godotengine/godot/issues/107078#issuecomment-2934597430
		var output_data = PackedByteArray()
		for b in im_width * im_height * im_depth * 4 * 4: # 4 bytes for 4 color channels
			output_data.push_back(0)
		var image_layers = [output_data]
		output_tex = rendering_device.texture_create(format, view, image_layers)
		output_tex_uniform = make_uniform_from_texture(output_tex, binding)
	return {
		"texture": output_tex,
		"uniform": output_tex_uniform
	}

func make_compute_sampler_uniform(rendering_device: RenderingDevice, texture: RID, binding: int = 0):
	var sampler_state = RDSamplerState.new()
	var sampler = rendering_device.sampler_create(sampler_state)

	var sampler_uniform = RDUniform.new()
	sampler_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	sampler_uniform.binding = binding
	sampler_uniform.add_id(sampler)
	sampler_uniform.add_id(texture)

	return {
		"sampler": sampler,
		"sampler_uniform": sampler_uniform
	}

func make_uniform_from_texture(output_tex: RID, binding: int = 0, ) -> RDUniform:
	print('making a uniform from texture...')
	var output_tex_uniform := RDUniform.new()
	output_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_tex_uniform.binding = binding
	output_tex_uniform.add_id(output_tex)
	return output_tex_uniform

func create_input_storage_uniform(
		rendering_device,
		configuration: PrecomputedAtmosphereConfiguration,
		input_output_texture_size: Vector2,
		input_target_dimensions: Vector4,
		binding: int = 0
	):
	var input_bytes = PackedFloat32Array([
		configuration.planet_radius,
		configuration.planet_radius + configuration.atmosphere_height,
		input_output_texture_size.x,
		input_output_texture_size.y,
		input_target_dimensions.x,
		input_target_dimensions.y,
		input_target_dimensions.z,
		input_target_dimensions.w,
		configuration.rayleigh_scattering.x,
		configuration.rayleigh_scattering.y,
		configuration.rayleigh_scattering.z,
		configuration.rayleigh_scale_height,
		configuration.mie_scattering.x,
		configuration.mie_scattering.y,
		configuration.mie_scattering.z,
		configuration.mie_scale_height
	]).to_byte_array()
	var buffer: RID = rendering_device.storage_buffer_create(input_bytes.size(), input_bytes)

	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return {
		"buffer": buffer,
		"uniform": uniform
	}

# Preprocesses #include statements
func preprocess_includes(input: String) -> String:
	input = input.replace("#include common.glsl", read_text_file(common_include_shader_file_path))
	input = input.replace("#include shading.glsl", read_text_file(shading_include_shader_file_path))
	input = input.replace("#include uniforms.glsl", read_text_file(uniforms_include_shader_file_path))
	input = input.replace("#include uniform_transmittance.glsl", read_text_file(uniform_transmittance_include_shader_file_path))
	return input

# Calculates the transmittance lut
func create_compute_shader_uniforms(
	rendering_device: RenderingDevice,
	configuration: PrecomputedAtmosphereConfiguration,
	compute_shader_source_code_path: String,
	width: int, height: int, depth: int,
	transmittance_lut: RID = RID(), # Transmittance lut is optional!
):
	print('compute texture dimensions: (', width, ', ', height, ', ', depth, ')')

	var texture_result = make_compute_texture(rendering_device, width, height, depth, 0)
	var output_texture_uniform = texture_result["uniform"]
	output_texture = texture_result["texture"]

	var buffer_result = create_input_storage_uniform(
		rendering_device,
		configuration,
		Vector2(width, height), Vector4(
			# Dimensions
			width,
			height,
			depth,
			1
		), 1)
	storage_buffer = buffer_result["buffer"]
	var storage_uniform = buffer_result["uniform"]

	var shader_source = RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	var source_code = read_text_file(compute_shader_source_code_path)
	source_code = preprocess_includes(source_code)
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_code)
	print('compiling spirv from source...')
	var shader_spirv = rendering_device.shader_compile_spirv_from_source(shader_source)
	print('creating a shader from spirv...')
	if shader_spirv.compile_error_compute != null:
		print('compile error: ', shader_spirv.compile_error_compute)
	compute_shader = rendering_device.shader_create_from_spirv(shader_spirv)

	print('creating a uniform set...')
	if transmittance_lut == RID():
		print('without transmittance lut...')
		uniform_set = rendering_device.uniform_set_create(
			[
				output_texture_uniform,
				storage_uniform
			],
			compute_shader,
			0 # the set ID
		)
	else:
		print('with transmittance lut...')
		var sampler_dict = make_compute_sampler_uniform(rendering_device, transmittance_lut, 2)
		var transmittance_lut_uniform = sampler_dict["sampler_uniform"]
		transmittance_lut_sampler = sampler_dict["sampler"]
		uniform_set = rendering_device.uniform_set_create(
			[
				output_texture_uniform,
				storage_uniform,
				transmittance_lut_uniform
			],
			compute_shader,
			0 # the set ID
		)

	# Create a compute pipeline
	print('creating pipeline...')
	pipeline = rendering_device.compute_pipeline_create(compute_shader)
	# self._render_process()

	# We don't need to sync up here, Godots default barriers will do the trick.
	# If you want the output of a compute shader to be used as input of
	# another computer shader you'll need to add a barrier:
	#rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)

	# texture2drd = load(self.texture_2drd_path)
	# texture2drd = load(self.texture_2drd_path)
	if depth > 1:
		print('assigning a 3d output texture rd...')
		output_texture_rd = Texture3DRD.new()
	else:
		print('assigning a 2d output texture rd...')
		output_texture_rd = Texture2DRD.new()
	set_output_texture_rd_rids()

	print('done!')
