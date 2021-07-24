//
//  Raytracer.swift
//  Basic Game Engine
//
//  Created by Ravi Khannawalia on 27/05/21.
//

import MetalKit
import MetalPerformanceShaders
import ModelIO

class Raytracer {
    var device: MTLDevice
    var commandQueue: MTLCommandQueue
    var library: MTLLibrary

    var rayPipeline: MTLComputePipelineState!
    var rayBuffer: MTLBuffer!
    var shadowRayBuffer: MTLBuffer!

    var shadePipelineState: MTLComputePipelineState!
    var accumulatePipeline: MTLComputePipelineState!
    var irradianceAccumulatePipeline: MTLComputePipelineState!
    var shadowAccumulatePipeline: MTLComputePipelineState!
    var varianceShadowMapPipeline: MTLComputePipelineState!
    var accumulationTarget: MTLTexture!
    var accelerationStructure: MPSTriangleAccelerationStructure!
    var shadowPipeline: MTLComputePipelineState!

    var vertexPositionBuffer: MTLBuffer!
    var vertexNormalBuffer: MTLBuffer!
    var vertexColorBuffer: MTLBuffer!
    var indexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var randomBuffer: MTLBuffer!
    var intersectionBuffer: MTLBuffer!
    let intersectionStride =
        MemoryLayout<MPSIntersectionDistancePrimitiveIndexCoordinates>.stride

    var intersector: MPSRayIntersector!
    let rayStride =
        MemoryLayout<MPSRayOriginMinDistanceDirectionMaxDistance>.stride
        + 4 * MemoryLayout<Float3>.stride// + MemoryLayout<Int32>.stride

    let maxFramesInFlight = 3
    let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 255) & ~255
    var semaphore: DispatchSemaphore!
    var size = CGSize.zero
    var randomBufferOffset = 0
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var frameIndex: UInt32 = 0
    var renderTarget: MTLTexture!
    weak var camera: Camera!
    weak var scene: Scene!
    var irradianceField: IrradianceField!

    lazy var vertexDescriptor: MDLVertexDescriptor = {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] =
            MDLVertexAttribute(name: MDLVertexAttributePosition,
                               format: .float3,
                               offset: 0, bufferIndex: 0)
        vertexDescriptor.attributes[1] =
            MDLVertexAttribute(name: MDLVertexAttributeNormal,
                               format: .float2,
                               offset: 0, bufferIndex: 1)
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float3>.stride)
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<Float3>.stride)
        return vertexDescriptor
    }()

    var vertices: [Float3] = []
    var normals: [Float3] = []
    var colors: [Float3] = []
    var minPosition: Float3 = Float3.zero
    var maxPosition: Float3 = Float3.zero

    init(metalView: MTKView) {
        device = Device.sharedDevice.device!
        semaphore = DispatchSemaphore(value: maxFramesInFlight)
        library = Device.sharedDevice.library!
        commandQueue = Device.sharedDevice.commandQueue!
        buildPipelines(view: metalView)
        createScene()
        createBuffers()
        buildIntersector()
        buildAccelerationStructure()
        irradianceField = IrradianceField(Constants.probeGrid.0, Constants.probeGrid.1, Constants.probeGrid.2, (minPosition + maxPosition)/2, (maxPosition - minPosition)*1.05)
   //     irradianceField = IrradianceField(Constants.probeGrid.0, Constants.probeGrid.1, Constants.probeGrid.2, Float3(-0, 7.5, 0), Float3(30, 18, 14))
   //     irradianceField = IrradianceField(Constants.probeGrid.0, Constants.probeGrid.1, Constants.probeGrid.2, Float3(-0, 1.5, 0), Float3(16, 2.5, 8.2))
   //     irradianceField = IrradianceField(Constants.probeGrid.0, Constants.probeGrid.1, Constants.probeGrid.2, Float3(-0, 10, 0), Float3(25, 25, 15))
    }

    func buildAccelerationStructure() {
        accelerationStructure =
            MPSTriangleAccelerationStructure(device: device)
        accelerationStructure?.vertexBuffer = vertexPositionBuffer
        accelerationStructure?.triangleCount = vertices.count / 3
        accelerationStructure?.rebuild()
    }

    func buildIntersector() {
        intersector = MPSRayIntersector(device: device)
        intersector?.rayDataType = .originMinDistanceDirectionMaxDistance
        intersector?.rayStride = rayStride
    }

    func buildPipelines(view: MTKView) {
        let vertexFunction = library.makeFunction(name: "vertexShaderRT")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.sampleCount = view.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        let computeDescriptor = MTLComputePipelineDescriptor()
        computeDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true

        do {
            computeDescriptor.computeFunction = library.makeFunction(
                name: "shadowKernel")
            shadowPipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )

            computeDescriptor.computeFunction = library.makeFunction(
                name: "shadeKernel")
            shadePipelineState = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )

            computeDescriptor.computeFunction = library.makeFunction(
                name: "accumulateKernel")
            accumulatePipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )
            
            computeDescriptor.computeFunction = library.makeFunction(
                name: "accumulateRadianceKernel")
            irradianceAccumulatePipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )
            
            computeDescriptor.computeFunction = library.makeFunction(
                name: "accumulateShadowKernel")
            shadowAccumulatePipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )
            
            computeDescriptor.computeFunction = library.makeFunction(
                name: "varianceShadowMapKernel")
            varianceShadowMapPipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )

            computeDescriptor.computeFunction = library.makeFunction(
                name: "primaryRays")
            rayPipeline = try device.makeComputePipelineState(
                descriptor: computeDescriptor,
                options: [],
                reflection: nil
            )

            //    renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print(error.localizedDescription)
        }
    }

    func createScene() {
        loadAsset(name: "pillarRoom")
    }

    func createBuffers() {
        let uniformBufferSize = alignedUniformsSize * maxFramesInFlight

        let options: MTLResourceOptions = {
            #if os(iOS)
                return .storageModeShared
            #else
                return .storageModeManaged
            #endif
        }()

        uniformBuffer = device.makeBuffer(length: uniformBufferSize, options: options)
        randomBuffer = device.makeBuffer(length: 256 * MemoryLayout<Float2>.stride * maxFramesInFlight, options: options)
        vertexPositionBuffer = device.makeBuffer(bytes: &vertices, length: vertices.count * MemoryLayout<Float3>.stride, options: options)
        vertexColorBuffer = device.makeBuffer(bytes: &colors, length: colors.count * MemoryLayout<Float3>.stride, options: options)
        vertexNormalBuffer = device.makeBuffer(bytes: &normals, length: normals.count * MemoryLayout<Float3>.stride, options: options)
    }

    func update() {
    //    GameTimer.sharedTimer.updateTime()
        updateUniforms()
        //   updateRandomBuffer()
        uniformBufferIndex = (uniformBufferIndex + 1) % maxFramesInFlight
    }

    func updateUniforms() {
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        let pointer = uniformBuffer!.contents().advanced(by: uniformBufferOffset)
        let uniforms = pointer.bindMemory(to: Uniforms_.self, capacity: 1)

        var camera = Camera_()
        //    camera.position = float3(8*sin(GameTimer.sharedTimer.time/10.0), 1.0, 8*cos(GameTimer.sharedTimer.time/10.0))
     //   camera.position = Float3(-17, 5, 0)
     //   camera.forward = self.camera.front
     //   camera.right = self.camera.right
     //   camera.up = self.camera.up

        //    camera.position = Float3(0, 1, -10)
        //    camera.forward = Float3(0.0, 0.0, -1.0)
        //    camera.right = Float3(1.0, 0.0, 0.0)
        //    camera.up = Float3(0.0, 1.0, 0.0)

     //   let fieldOfView = 45.0 * (Float.pi / 180.0)
     //   let aspectRatio = Float(Constants.probeReso) / Float(Constants.probeReso)
     //   let imagePlaneHeight = tanf(fieldOfView / 2.0)
     //   let imagePlaneWidth = aspectRatio * imagePlaneHeight

     //   camera.right *= imagePlaneWidth
     //   camera.up *= imagePlaneHeight

        //     print(camera.right!)
        var light = AreaLight()
     //   light.position = Float3(5000, 10000, 5000)
     //   light.forward = Float3(0.0, 0.0, -1.0)
     //   light.right = Float3(1.0, 0.0, 0.0)
     //   light.up = Float3(0.0, 1.0, 0.0)
     //   light.color = Float3(4.0, 4.0, 4.0)
        var lightProbe = LightProbeData_()
        lightProbe.gridEdge = irradianceField.gridEdge
        lightProbe.gridOrigin = irradianceField.origin
        lightProbe.probeCount = SIMD3<Int32>(Int32(Constants.probeGrid.0), Int32(Constants.probeGrid.1), Int32(Constants.probeGrid.2))

        uniforms.pointee.camera = camera
        uniforms.pointee.light = light
        uniforms.pointee.sunDirection = scene.sunDirection.normalized
        uniforms.pointee.probeData = lightProbe

        uniforms.pointee.probeWidth = Int32(Constants.probeReso)
        uniforms.pointee.probeHeight = Int32(Constants.probeReso)
        uniforms.pointee.probeGridWidth = Int32(Constants.probeGrid.0)
        uniforms.pointee.probeGridHeight = Int32(Constants.probeGrid.1)
        uniforms.pointee.width = UInt32(size.width)
        uniforms.pointee.height = UInt32(size.height)
        uniforms.pointee.blocksWide = (uniforms.pointee.width + 15) / 16
        uniforms.pointee.frameIndex = frameIndex
        frameIndex += 1
        //  print(self.camera.position)
        #if os(OSX)
            uniformBuffer?.didModifyRange(uniformBufferOffset ..< (uniformBufferOffset + alignedUniformsSize))
        #endif
    }
}

extension Raytracer {
    func mtkView(_: MTKView, drawableSizeWillChange size: CGSize) {
        self.size = size
        frameIndex = 0
        let renderTargetDescriptor = MTLTextureDescriptor()
        renderTargetDescriptor.pixelFormat = .rgba32Float
        renderTargetDescriptor.textureType = .type2D
        renderTargetDescriptor.width = Int(Constants.probeReso)
        renderTargetDescriptor.height = Int(Constants.probeReso)
        renderTargetDescriptor.storageMode = .private
        renderTargetDescriptor.usage = [.shaderRead, .shaderWrite]
        renderTarget = device.makeTexture(descriptor: renderTargetDescriptor)

        let rayCount = Int(size.width * size.height)
        rayBuffer = device.makeBuffer(length: rayStride * rayCount,
                                      options: .storageModePrivate)
        shadowRayBuffer = device.makeBuffer(length: rayStride * rayCount,
                                            options: .storageModePrivate)

        accumulationTarget = device.makeTexture(
            descriptor: renderTargetDescriptor)

        intersectionBuffer = device.makeBuffer(
            length: intersectionStride * rayCount,
            options: .storageModePrivate
        )
    }

    func drawAccumulation(in _: MTKView, commandBuffer: MTLCommandBuffer?) {
        // MARK: accumulation

        guard let commandBuffer = commandBuffer else {
            return
        }
        let threadsPerGroup_ = MTLSizeMake(8, 4, 1)
        let probeCount = Constants.probeGrid.0 * Constants.probeGrid.1
        let threadGroups_ = MTLSizeMake(
            (probeCount + threadsPerGroup_.width - 1) / threadsPerGroup_.width,
            (Constants.probeGrid.2 + threadsPerGroup_.height - 1) / threadsPerGroup_.height, 1
        )
        var computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder?.label = "Accumulation"
        computeEncoder?.setBuffer(uniformBuffer, offset: uniformBufferOffset,
                                  index: 0)
        computeEncoder?.setBuffer(irradianceField.probes, offset: 0, index: 1)
        computeEncoder?.setBuffer(rayBuffer, offset: 0, index: 2)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureR, index: 0)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureG, index: 1)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureB, index: 2)
        computeEncoder?.setComputePipelineState(accumulatePipeline)
        computeEncoder?.dispatchThreadgroups(threadGroups_,
                                             threadsPerThreadgroup: threadsPerGroup_)
        computeEncoder?.endEncoding()
        
        let width = Int(Constants.probeCount * Constants.radianceProbeReso)
        let height = Int(Constants.radianceProbeReso)
        let threadsPerGroup = MTLSizeMake(8, 8, 1)
        let threadGroups = MTLSizeMake(
            (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            (height + threadsPerGroup.height - 1) / threadsPerGroup.height, 1
        )
        
        computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder?.label = "IrradianceAccumulation"
        computeEncoder?.setBuffer(uniformBuffer, offset: uniformBufferOffset,
                                  index: 0)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureR, index: 0)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureG, index: 1)
        computeEncoder?.setTexture(irradianceField.ambientCubeTextureB, index: 2)
        computeEncoder?.setTexture(irradianceField.radianceMap, index: 3)
        computeEncoder?.setTexture(irradianceField.specularMap, index: 4)
        computeEncoder?.setComputePipelineState(irradianceAccumulatePipeline)
        computeEncoder?.dispatchThreadgroups(threadGroups,
                                             threadsPerThreadgroup: threadsPerGroup)
        computeEncoder?.endEncoding()
    }
    
    func updateShadowMap(shadowMap: MTLTexture, newShadowMap: MTLTexture, commandBuffer: MTLCommandBuffer?) {
        let width = shadowMap.width
        let height = shadowMap.height
        guard let commandBuffer = commandBuffer else {
            return
        }
        let threadsPerGroup = MTLSizeMake(16, 16, 1)
        let threadGroups = MTLSizeMake(
            (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            (height + threadsPerGroup.height - 1) / threadsPerGroup.height, 1
        )
        
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder?.label = "varianceShadowMap"
        computeEncoder?.setTexture(shadowMap, index: 0)
        computeEncoder?.setTexture(newShadowMap, index: 1)
        computeEncoder?.setComputePipelineState(varianceShadowMapPipeline)
        computeEncoder?.dispatchThreadgroups(threadGroups,
                                             threadsPerThreadgroup: threadsPerGroup)
        computeEncoder?.endEncoding()
    }

    func draw(in _: MTKView, commandBuffer: MTLCommandBuffer?) {
        //   print(frameIndex, size.width, size.height, size.width * size.height * 6)
        semaphore.wait()
        guard let commandBuffer = commandBuffer else {
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.semaphore.signal()
        }
        update()

        // MARK: generate rays

        let width = Int(size.width)
        let height = Int(size.height)
        let threadsPerGroup = MTLSizeMake(8, 8, 1)
        let threadGroups = MTLSizeMake(
            (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            (height + threadsPerGroup.height - 1) / threadsPerGroup.height, 1
        )
        var computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder?.label = "Generate Rays"
        computeEncoder?.setBuffer(uniformBuffer, offset: uniformBufferOffset,
                                  index: 0)
        computeEncoder?.setBuffer(rayBuffer, offset: 0, index: 1)
        computeEncoder?.setBuffer(randomBuffer, offset: randomBufferOffset,
                                  index: 2)
        computeEncoder?.setBuffer(irradianceField.probes, offset: 0, index: 3)
        computeEncoder?.setBuffer(irradianceField.probeDirections, offset: Constants.probeReso * Constants.probeReso, index: 4)
        computeEncoder?.setTexture(renderTarget, index: 0)
        computeEncoder?.setComputePipelineState(rayPipeline)
        computeEncoder?.dispatchThreadgroups(threadGroups,
                                             threadsPerThreadgroup: threadsPerGroup)
        computeEncoder?.endEncoding()

        for _ in 0 ..< 1 {
            // MARK: generate intersections between rays and model triangles

            intersector?.intersectionDataType = .distancePrimitiveIndexCoordinates
            intersector?.encodeIntersection(
                commandBuffer: commandBuffer,
                intersectionType: .nearest,
                rayBuffer: rayBuffer,
                rayBufferOffset: 0,
                intersectionBuffer: intersectionBuffer,
                intersectionBufferOffset: 0,
                rayCount: width * height,
                accelerationStructure: accelerationStructure
            )

            // MARK: shading

            computeEncoder = commandBuffer.makeComputeCommandEncoder()
            computeEncoder?.label = "Shading"
            computeEncoder?.setBuffer(uniformBuffer, offset: uniformBufferOffset,
                                      index: 0)
            computeEncoder?.setBuffer(rayBuffer, offset: 0, index: 1)
            computeEncoder?.setBuffer(shadowRayBuffer, offset: 0, index: 2)
            computeEncoder?.setBuffer(intersectionBuffer, offset: 0, index: 3)
            computeEncoder?.setBuffer(vertexColorBuffer, offset: 0, index: 4)
            computeEncoder?.setBuffer(vertexNormalBuffer, offset: 0, index: 5)
            computeEncoder?.setBuffer(irradianceField.probes, offset: 0, index: 6)
            computeEncoder?.setTexture(scene.irradianceMap.texture, index: 0)
            computeEncoder?.setTexture(irradianceField.octaHedralMap!, index: 1)
            computeEncoder?.setTexture(irradianceField.radianceMap!, index: 2)
            computeEncoder?.setComputePipelineState(shadePipelineState!)
            computeEncoder?.dispatchThreadgroups(
                threadGroups,
                threadsPerThreadgroup: threadsPerGroup
            )
            computeEncoder?.endEncoding()

            // MARK: shadows

            intersector?.label = "Shadows Intersector"
            intersector?.intersectionDataType = .distance
            intersector?.encodeIntersection(
                commandBuffer: commandBuffer,
                intersectionType: .any,
                rayBuffer: shadowRayBuffer,
                rayBufferOffset: 0,
                intersectionBuffer: intersectionBuffer,
                intersectionBufferOffset: 0,
                rayCount: width * height,
                accelerationStructure: accelerationStructure
            )

            computeEncoder = commandBuffer.makeComputeCommandEncoder()
            computeEncoder?.label = "Shadows"
            computeEncoder?.setBuffer(uniformBuffer, offset: uniformBufferOffset,
                                      index: 0)
            computeEncoder?.setBuffer(shadowRayBuffer, offset: 0, index: 1)
            computeEncoder?.setBuffer(intersectionBuffer, offset: 0, index: 2)
            computeEncoder?.setBuffer(irradianceField.probes, offset: 0, index: 3)
        //    computeEncoder?.setBuffer(irradianceField.probeLocations, offset: 0, index: 3)
        //    computeEncoder?.setBuffer(irradianceField.probeDirections, offset: Constants.probeReso * Constants.probeReso, index: 4)
            computeEncoder?.setTexture(renderTarget, index: 0)
            computeEncoder?.setTexture(irradianceField.ambientCubeTextureR!, index: 1)
            computeEncoder?.setTexture(irradianceField.ambientCubeTextureG!, index: 2)
            computeEncoder?.setTexture(irradianceField.ambientCubeTextureB!, index: 3)
            computeEncoder?.setTexture(irradianceField.octaHedralMap!, index: 4)
            computeEncoder?.setComputePipelineState(shadowPipeline!)
            computeEncoder?.dispatchThreadgroups(
                threadGroups,
                threadsPerThreadgroup: threadsPerGroup
            )
            computeEncoder?.endEncoding()
        }
        
        let width_ = Constants.probeGrid.0 * Constants.probeGrid.1 * Constants.shadowProbeReso
        let height_ = Constants.probeGrid.2 * Constants.radianceProbeReso
        let threadsPerGroup_ = MTLSizeMake(16, 16, 1)
        let threadGroups_ = MTLSizeMake(
            (width_ + threadsPerGroup.width - 1) / threadsPerGroup.width,
            (height_ + threadsPerGroup.height - 1) / threadsPerGroup.height, 1
        )
        
        computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder?.label = "ShadowAccumulation"
        computeEncoder?.setBuffer(uniformBuffer, offset: 0, index: 0)
        computeEncoder?.setTexture(irradianceField.octaHedralMap, index: 0)
        computeEncoder?.setTexture(irradianceField.depthMap, index: 1)
        computeEncoder?.setComputePipelineState(shadowAccumulatePipeline)
        computeEncoder?.dispatchThreadgroups(threadGroups_,
                                             threadsPerThreadgroup: threadsPerGroup_)
        computeEncoder?.endEncoding()

//      guard let descriptor = view.currentRenderPassDescriptor,
//        let renderEncoder = commandBuffer.makeRenderCommandEncoder(
//          descriptor: descriptor) else {
//            return
//      }
        //  //    renderEncoder.setRenderPipelineState(renderPipeline!)
//
//      // MARK: draw call
//      renderEncoder.setFragmentTexture(accumulationTarget, index: 0)
//      renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
//      renderEncoder.endEncoding()
//      guard let drawable = view.currentDrawable else {
//        return
//      }
//      commandBuffer.present(drawable)
    }
}

extension Raytracer {
    func loadAsset(name modelName: String, position: Float3 = [0, 0, 0], scale: Float = 1) {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "obj") else { return }
        let bufferAllocator_ = MTKMeshBufferAllocator(device: device)
        let asset_ = MDLAsset(url: url, vertexDescriptor: Self.getMDLVertexDescriptor(), bufferAllocator: bufferAllocator_)
        asset_.loadTextures()
        var meshes: [MTKMesh]
        var meshesMDL: [MDLMesh]
        do {
            try (meshesMDL, meshes) = MTKMesh.newMeshes(asset: asset_, device: device)
            //    allMeshes[modelName] = (meshesMDL, meshes)
        } catch let error as NSError {
            fatalError(error.description)
        }
        let subMeshesMDL = meshesMDL.map { mdlMesh in
            return mdlMesh.submeshes as! [MDLSubmesh]
        }
        //    return (meshesMDL, meshes)
        for (meshIndex, mesh) in meshes.enumerated() {
            for vertexBuffer in mesh.vertexBuffers {
                let count = vertexBuffer.buffer.length / MemoryLayout<VertexIn>.stride
                let ptr = vertexBuffer.buffer.contents().bindMemory(to: VertexIn.self, capacity: count)

                for (mdlIndex, submesh) in mesh.submeshes.enumerated() {
                    let indexBuffer = submesh.indexBuffer.buffer
                    let offset = submesh.indexBuffer.offset
                    let indexPtr = indexBuffer.contents().advanced(by: offset)
                    var indices = indexPtr.bindMemory(to: uint.self, capacity: submesh.indexCount)
                    for _ in 0 ..< submesh.indexCount {
                        let index = Int(indices.pointee)
                        let vertex = ptr[index]
                        //    vertices_.append(ptr[index])
                        let vPosition = vertex.position * scale + position
                        minPosition = min(vPosition, minPosition)
                        maxPosition = max(vPosition, maxPosition)
                        vertices.append(vPosition)
                        normals.append(vertex.normal)
                        var color = Float3(1, 1, 1)
                        let mdlSubmesh = subMeshesMDL[meshIndex][mdlIndex]
                        if let baseColor = mdlSubmesh.material?.property(with: .baseColor),
                          baseColor.type == .float3 {
                          color = baseColor.float3Value
                        }
                    //    color = Float3(1, 1, 1);
                        colors.append(color)
                        indices = indices.advanced(by: 1)
                    }
                }
            }
        }
    }

    static func getMDLVertexDescriptor() -> MDLVertexDescriptor {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: MemoryLayout<Float>.size * 3, bufferIndex: 0)
        vertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: MemoryLayout<Float>.size * 6, bufferIndex: 0)
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 8)
        return vertexDescriptor
    }

    struct VertexIn {
        var pos: Float3_
        var n: Float3_
        var tex: Float2_
    }

    struct Float3_ {
        var x: Float
        var y: Float
        var z: Float
    }

    struct Float2_ {
        var x: Float
        var y: Float
    }
}

extension Raytracer.VertexIn {
    var position: Float3 {
        return Float3(pos.x, pos.y, pos.z)
    }

    var normal: Float3 {
        return Float3(n.x, n.y, n.z)
    }
}
