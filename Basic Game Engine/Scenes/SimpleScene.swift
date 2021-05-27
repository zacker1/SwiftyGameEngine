//
//  SimpleScene.swift
//  Basic Game Engine
//
//  Created by Ravi Khannawalia on 31/01/21.
//

import MetalKit

class SimpleScene: Scene {
    
    var blades: GameObject!
    var model: GameObject!
    var model2: GameObject!
    
    override func getGameObjects() -> [GameObject] {
        model = GameObject(modelName: "sponza")
        model2 = GameObject(modelName: "plane")
        model2.transform.position = Float3(30, 20, 0)
        model2.transform.scale(Float3(repeating: 10))
        model2.transform.rotate(angle: MathConstants.PI.rawValue/2, axis: Float3(0, 0, 1))
        model2.transform.rotate(angle: MathConstants.PI.rawValue/2, axis: Float3(0, 1, 0))
        return [model, model2]
    }
    
    override func addPhysics() {
        
    }
    
    override func getSkybox() -> Skybox {
        return Skybox(textureName: "park")
    }
    
    override func addBehaviour() {
    //    let _ = MoveInCircle(gameObject: model2, radius: 15)
    //    let _ = RotateZ(gameObject: model, speed: 0.1)
    }
    
    override func getCamera() -> Camera {
        return Camera(position: Float3(0, 0, 15), target: Float3(0, 0, 0))
    }
}
