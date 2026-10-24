# RealityKit API inventory (names only)

Generated 2026-10-19 by KIT-REALITYKIT from the iPhoneSimulator 27.1
SDK's `.swiftinterface` files (level 4) with our own script
(`research/experiments/realitykit/inventory/`). It lists **names,
argument labels, kinds, protocol conformances and availability** — no
types, signatures, default values or documentation text. SPI, internal
and underscore-prefixed declarations are omitted; `==`, hashing and
`Codable` boilerplate members are omitted. "unannotated" means the member
inherits availability from its enclosing declaration (our script does not
propagate it); "not iOS" members exist for visionOS only.

Use it as a checklist of the surface an implementation round must
provide; behaviour is specified in files 01–08.

## Module `RealityFoundation`


### `Entity` — class (iOS 13.0); conforms to HasHierarchy, HasSynchronization, HasTransform, Sendable
  - iOS 15.0: `bindableValues`, `parameters`, `moveCharacter(by:deltaTime:relativeTo:collisionHandler:)`, `teleportCharacter(to:relativeTo:)`, `characterController`, `characterControllerState`, `playAnimation(_:transitionDuration:blendLayerOffset:separateAnimatedValue:startsPaused:clock:)`, `defaultAnimationClock`
  - iOS 18.0, visionOS 2.0: `subscript(entityPath:)`, `playAudio(configuration:_:)`, `prepareAudio(configuration:_:)`, `init(from:configurations:)`, `applyTapForBehaviors()`, `write(to:)`, `pins`
  - iOS 18.0, visionOS 1.0: conforms to RealityCoordinateSpace, `spatialAudio`, `generateCollisionShapes(recursive:static:)`, `channelAudio`, `init(named:in:)`, `init(contentsOf:withName:)`, `ambientAudio`, `playAnimation(_:transitionDuration:blendLayerOffset:separateAnimatedValue:startsPaused:clock:handoffType:)`
  - iOS 13.0: conforms to CustomDebugStringConvertible, `debugDescription`, `availableAnimations`, `playAudio(_:)`, `prepareAudio(_:)`, `stopAllAudio()`, `generateCollisionShapes(recursive:)`, `anchor`, `components`, `scene`, `name`, `isActive`, `isAnchored`, `isEnabled`, `isEnabledInHierarchy`, `init()`, `didClone(from:)`, `findEntity(named:)`, conforms to Hashable, conforms to Identifiable, `id`, `clone(recursive:)`, conforms to EventSource, `static load(named:in:)`, `static load(contentsOf:withName:)`, `static loadAnchor(named:in:)`, `static loadAnchor(contentsOf:withName:)`, `playAnimation(_:transitionDuration:startsPaused:)`, `stopAllAnimations(recursive:)`
  - iOS 27.0, visionOS 27.0: `playAudio(_:at:)`, `init(from:named:contentType:)`
  - iOS 26.0, visionOS 26.0: `attach(_:to:)`, `observable`, conforms to Observable
  - not iOS, visionOS 2.0: `transformMatrix(relativeTo:)`
  - iOS 14.0: `isAccessibilityElement`
  - deprecated: `accessibilityLabel`, `accessibilityDescription`, `static loadAsync(named:in:)`, `static loadAsync(contentsOf:withName:)`, `static loadAnchorAsync(named:in:)`, `static loadAnchorAsync(contentsOf:withName:)`, `static loadModelAsync(named:in:)`, `static loadModelAsync(contentsOf:withName:)`, `init(from:named:)`, `playAnimation(named:transitionDuration:startsPaused:recursive:)`
  - not visionOS: `static loadBodyTracked(named:in:)`, `static loadBodyTracked(contentsOf:withName:)`
  - not visionOS, deprecated: `static loadBodyTrackedAsync(named:in:)`, `static loadBodyTrackedAsync(contentsOf:withName:)`
  - iOS 13.0, visionOS 1.0: `static loadModel(named:in:)`, `static loadModel(contentsOf:withName:)`, `init(components:)`
  - not iOS, visionOS 26.0: conforms to CoordinateSpace3DFloat, `ancestorFromSpaceTransformFloat()`, `ancestorSpace`, `transform(from:)`

### `DirectionalLightComponent` — struct (iOS 13.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 13.0, visionOS 2.0: `intensity`
  - not visionOS: `isRealWorldProxy`
  - iOS 27.0, visionOS 27.0: `layers`

### `DirectionalLightComponent.Shadow` — struct; conforms to Component, Equatable
  - iOS 13.0, visionOS 2.0: `depthBias`, `init()`, `init(maximumDistance:depthBias:)`
  - not visionOS, deprecated: `maximumDistance`
  - iOS 18.0, visionOS 2.0: `cullModeOverride`, `shadowProjection`, `init(shadowProjection:depthBias:cullMode:)`
  - iOS 27.0, visionOS 27.0: `cascades`, `layers`, `init(layers:)`

### `DirectionalLightComponent.Shadow.ShadowProjectionType` — enum; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `.fixed(...)`, `.automatic(...)`

### `DirectionalLightComponent.Shadow.Cascades` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `static fixed(_:bias:)`, `static automatic`

### `EnvironmentBlendingComponent` — struct (not iOS, visionOS 26.0); conforms to Component, Equatable
  - not iOS, visionOS 26.0: `preferredBlendingMode`, `init()`, `init(preferredBlendingMode:)`

### `EnvironmentBlendingComponent.EnvironmentType` — enum; conforms to Equatable, Hashable, Sendable
  - not iOS, visionOS 26.0: `.surroundings`

### `EnvironmentBlendingComponent.BlendingMode` — struct; conforms to Equatable, Hashable, Sendable
  - not iOS, visionOS 26.0: `static default`, `static occluded(by:)`

### `FromToByAnimation` — struct (iOS 15.0); conforms to AnimationDefinition where Value : AnimatableData
  - iOS 15.0: `name`, `blendLayer`, `bindTarget`, `fillMode`, `isAdditive`, `timing`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`, `init(name:from:to:by:duration:timing:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `fromValue`, `toValue`, `byValue`, `jointNames`, `isScaleAnimated`, `isRotationAnimated`, `isTranslationAnimated`, `init(jointNames:name:isScaleAnimated:isRotationAnimated:isTranslationAnimated:from:to:by:duration:timing:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`
  - iOS 18.0, visionOS 2.0: `weightNames`, `fromValue`, `toValue`, `byValue`, `init(weightNames:name:from:to:by:duration:timing:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`
  - unannotated: `init(name:from:to:by:duration:additive:targetPath:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`

### `MeshDeformerComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component, Sendable
  - iOS 27.0, visionOS 27.0: `deformations`

### `BindPath` — struct (iOS 15.0)
  - iOS 15.0: `parts`

### `BindPath.Part` — enum; conforms to Equatable
  - iOS 15.0: `.scene(...)`, `.anchorEntity(...)`, `.entity(...)`, `.parameter(...)`, `.transform`, `.jointTransforms`
  - iOS 27.0, visionOS 27.0: `.rootMotion`
  - iOS 18.0, visionOS 1.0: `.opacity`, `.material(...)`, `.materialParameter(...)`
  - iOS 18.0, visionOS 2.0: `.blendShapeWeights`, `.blendShapeWeightsAtIndex(...)`, `.blendShapeWeightsWithID(...)`, `.billboardBlendFactor`, `.ikSolver(...)`, `.ikConstraintTarget(...)`, `.ikConstraintLookAtTarget(...)`, `.skeletalPose(...)`

### `BindTarget` — enum (iOS 15.0); conforms to Equatable
  - iOS 15.0: `.internal(...)`, `.transform`, `.jointTransforms`, `.parameter(...)`, `.path(...)`, `static scene(_:)`, `static anchorEntity(_:)`, `static entity(_:)`
  - iOS 18.0, visionOS 1.0: `.opacity`, `static material(_:)`
  - iOS 18.0, visionOS 2.0: `.blendShapeWeights`, `.blendShapeWeightsAtIndex(...)`, `.blendShapeWeightsWithID(...)`, `.billboardBlendFactor`, `.skeletalPose(...)`
  - iOS 27.0, visionOS 27.0: `.rootMotion`

### `BindTarget.ScenePath` — struct
  - iOS 15.0: `anchorEntity(_:)`, `self`

### `BindTarget.TextureCoordinateTransformPath` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `offset`

### `BindTarget.MaterialPath` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `baseColorTint`, `roughnessScale`, `metallicScale`, `specularScale`, `sheenTint`, `clearcoatScale`, `clearcoatRoughnessScale`, `anisotropyLevelScale`, `anisotropyAngleScale`, `emissiveColor`, `emissiveIntensity`, `opacityThreshold`, `textureCoordinate`, `secondaryTextureCoordinate`, `customValue`

### `BindTarget.EntityPath` — struct
  - iOS 15.0: `entity(_:)`, `transform`, `jointTransforms`, `parameter(_:)`, `self`
  - iOS 27.0, visionOS 27.0: `rootMotion`
  - iOS 18.0, visionOS 2.0: `blendShapeWeights()`, `blendShapeWeightsAtIndex(_:)`, `blendShapeWeightsWithID(_:)`, `billboardBlendFactor`, `skeletalPose(_:)`, `ikSolver(_:)`
  - iOS 18.0, visionOS 1.0: `opacity`, `material(_:)`

### `BindTarget.IkSolverPath` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `constraintTarget(_:)`, `constraintLookAtTarget(_:)`

### `InternalBindPath` — struct (iOS 15.0)

### `BindableData` — protocol (iOS 15.0)
- extension of `Float`
  - iOS 15.0: conforms to BindableData, conforms to AnimatableData
- extension of `Double`
  - iOS 15.0: conforms to BindableData, conforms to AnimatableData
- extension of `SIMD2`
- extension of `SIMD3`
- extension of `SIMD4`
- extension of `simd_quatf`
  - iOS 15.0: conforms to BindableData, conforms to AnimatableData

### `Transform` — struct (iOS 13.0); conforms to Component, Hashable
  - iOS 15.0: conforms to BindableData, conforms to AnimatableData
  - iOS 18.0, visionOS 1.0: `init(_:)`
  - iOS 26.0, visionOS 26.0: conforms to ProjectiveTransformable3DFloat, `applying(_:)`, `init(projectiveTransform:)`
  - iOS 13.0: `static identity`, `scale`, `rotation`, `translation`, `matrix`, `init()`, `init(scale:rotation:translation:)`, `init(pitch:yaw:roll:)`, `init(matrix:)`, conforms to Sendable, conforms to BitwiseCopyable
  - iOS 18.0, visionOS 2.0: conforms to Codable
- extension of `Bool`
  - iOS 15.0: conforms to BindableData
- extension of `Int`
  - iOS 15.0: conforms to BindableData
- extension of `String`
  - iOS 15.0: conforms to BindableData

### `BindableValue` — struct (iOS 15.0); conforms to BindableData
  - iOS 15.0: `init(_:animatedValue:)`, `value`, `baseValue`, `animatedValue`

### `BindableValuesReference` — struct (iOS 15.0)
  - iOS 15.0: `subscript(bindTarget:type:)`

### `ParameterSet` — struct (iOS 15.0)
  - iOS 15.0: `subscript(name:type:)`

### `Entity.ParameterSet` — struct
  - iOS 15.0: `subscript(name:type:)`

### `RetargetingConfiguration` — class
  - unannotated: `sourceSkeleton`, `targetSkeleton`, `static automatchBiped(_:to:jointOffsets:)`, `static automatchBiped(_:sourceTransform:to:targetTransform:jointOffsets:)`, `static automatchQuadruped(_:sourceTransform:to:targetTransform:jointOffsets:)`

### `AudioFileResource` — class; conforms to AudioResource
  - unannotated: `name`
  - iOS 18.0, visionOS 1.0: `configuration`, conforms to Hashable, `duration`, `init(named:in:configuration:)`, `init(named:from:in:)`, `init(contentsOf:withName:configuration:)`, `static load(contentsOf:withName:configuration:)`, `static load(named:in:configuration:)`, `static load(named:from:in:)`
  - deprecated: `loadingStrategy`, `shouldLoop`
  - iOS 27.0, visionOS 27.0: `init(from:configuration:)`
  - not visionOS, deprecated: `static load(named:in:inputMode:loadingStrategy:shouldLoop:)`, `static load(contentsOf:withName:inputMode:loadingStrategy:shouldLoop:)`, `static loadAsync(named:in:inputMode:loadingStrategy:shouldLoop:)`, `static loadAsync(contentsOf:withName:inputMode:loadingStrategy:shouldLoop:)`

### `AudioFileResource.LoadingStrategy` — enum
  - iOS 13.0: `.stream`, `.preload`, conforms to Hashable
  - iOS 15.0: conforms to Codable
  - iOS 18.0, visionOS 1.0: conforms to Sendable, conforms to RawRepresentable, `rawValue`, `init(rawValue:)`

### `ReverbComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `reverb`, `init(reverb:)`
- extension of `simd_float4x4`

### `Audio` — enum (iOS 18.0, visionOS 1.0)
  - iOS 27.0, visionOS 27.0: `static prepareAudio(_:)`, `static playAudio(_:)`, `static playAudio(_:at:)`

### `Audio.DistanceAttenuation` — enum
  - iOS 18.0, visionOS 2.0: `.rolloff(...)`, `static default`, conforms to Equatable, Hashable, Codable

### `AudioResource` — class; conforms to Resource
  - not visionOS, deprecated: `inputMode`
  - iOS 18.0, visionOS 1.0: conforms to Equatable

### `AudioResource.InputMode` — enum (not visionOS, deprecated)
  - not visionOS, deprecated: `.nonSpatial`, `.spatial`, `.ambient`, conforms to Equatable, conforms to Hashable

### `AudioLibraryComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, ExpressibleByDictionaryLiteral
  - iOS 18.0, visionOS 2.0: `resources`, `init(resources:)`, `init(dictionaryLiteral:)`

### `ImageBasedLightComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 1.0: `source`, `inheritsRotation`, `intensityExponent`, `init(source:intensityExponent:)`

### `ImageBasedLightComponent.Source` — enum
  - iOS 18.0, visionOS 1.0: `.none`, `.single(...)`, `.blend(...)`

### `ImageBasedLightReceiverComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 1.0: `imageBasedLight`, `init(imageBasedLight:)`

### `AnimationGraphResource` — class (iOS 27.0, visionOS 27.0); conforms to Resource, @unchecked Sendable
  - iOS 27.0, visionOS 27.0: `static validate(definition:nodeResourceMapping:skeletonResource:)`, `init(definition:nodeResourceMapping:skeletonResource:)`, `parameterNames`

### `HasModel` — protocol (iOS 13.0); conforms to HasTransform
  - iOS 13.0: `model`, `debugModel`, `jointNames`, `jointTransforms`
  - iOS 14.0: `modelDebugOptions`
  - iOS 18.0, visionOS 2.0: `blendWeights`, `blendWeightNames`

### `SceneUnderstandingComponent` — struct (iOS 13.4, visionOS 1.0); conforms to Component
  - iOS 15.0, visionOS 1.0: `init(entityType:)`, `init()`, `entityType`
  - iOS 18.0, visionOS 1.0: `origin`

### `SceneUnderstandingComponent.EntityType` — enum (iOS 15.0, visionOS 1.0); conforms to Hashable
  - iOS 15.0, visionOS 1.0: `.meshChunk`
  - not visionOS: `.face`

### `SceneUnderstandingComponent.Origin` — enum; conforms to Hashable
  - iOS 18.0, visionOS 1.0: `.system`, `.user`

### `ToneMappingComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `exposure`, `toeStrength`, `toeLength`, `shoulderStrength`, `shoulderLength`, `shoulderAngle`, `init(exposure:toeStrength:toeLength:shoulderStrength:shoulderLength:shoulderAngle:)`

### `EntityQuery` — struct (iOS 15.0); conforms to @unchecked Sendable
  - iOS 15.0: `init()`, `init(where:)`

### `BehaviorTreeResource` — class (iOS 27.0, visionOS 27.0); conforms to Resource, @unchecked Sendable
  - iOS 27.0, visionOS 27.0: `static validate(definition:)`, `init(definition:)`, `parameterNames`

### `Scene` — class
  - iOS 15.0: `performQuery(_:)`
  - iOS 13.0: `subscribe(to:on:_:)`, `publisher(for:on:)`, `subscribe(to:on:componentType:_:)`, `publisher(for:on:componentType:)`, conforms to Hashable, conforms to Identifiable, `id`, conforms to EventSource, `raycast(origin:direction:length:query:mask:relativeTo:)`, `raycast(from:to:query:mask:relativeTo:)`, `convexCast(convexShape:fromPosition:fromOrientation:toPosition:toOrientation:query:mask:relativeTo:)`, conforms to Sendable
  - unannotated: `name`, `findEntity(named:)`, `synchronizationService`
  - not visionOS: `anchors`, `addAnchor(_:)`, `removeAnchor(_:)`
  - iOS 18.0, visionOS 1.0: `findEntity(id:)`, `timebase`
  - iOS 27.0, visionOS 27.0: `commandQueue`
  - not iOS, visionOS 26.0: conforms to CoordinateSpace3DFloat, `ancestorFromSpaceTransformFloat()`, `ancestorSpace`, `transform(from:)`
  - iOS 18.0, not visionOS: `pixelCast(origin:direction:length:)`, `pixelCast(from:to:)`

### `SynchronizationPeerID` — protocol (iOS 13.0)

### `SynchronizationService` — protocol (iOS 13.0); conforms to AnyObject
  - iOS 13.0: `entity(for:)`, `owner(of:)`, `giveOwnership(of:toPeer:)`

### `NetworkCompatibilityToken` — class; conforms to Codable
  - unannotated: `static local`, `compatibilityWith(_:)`

### `NetworkCompatibilityToken.Compatibility` — enum
  - unannotated: `.compatible`, `.sessionProtocolVersionMismatch`
  - iOS 13.4: conforms to Equatable, conforms to Hashable

### `TextureResource` — class; conforms to Resource
  - unannotated: `static load(contentsOf:withName:)`
  - iOS 15.0: `semantic`, `width`, `height`, `mipmapLevelCount`, `static load(contentsOf:withName:options:)`, `replace(withImage:options:)`, `copy(to:)`, `replace(withDrawables:)`, `drawableQueue`
  - iOS 18.0, visionOS 2.0: `depth`, `pixelFormat`, `textureType`, `arrayLength`, `static texture2DArray(slices:named:options:)`, `static cube(slices:named:options:)`, `static texture3D(slices:named:options:)`, `init(cubeFromEquirectangular:named:quality:faceSize:options:)`, `init(cubeFromImage:named:options:)`, `init(image:withName:options:)`, `init(dimensions:format:contents:)`, `replace(with:)`
  - deprecated: `static loadAsync(contentsOf:withName:)`, `static loadAsync(contentsOf:withName:options:)`, `static generate(from:withName:options:)`, `replaceAsync(withImage:options:)`, `copyAsync(to:completionHandler:)`
  - iOS 15.0, deprecated: `static generateAsync(from:withName:options:)`
  - iOS 18.0, visionOS 1.0: `init(contentsOf:withName:)`, `init(contentsOf:withName:options:)`, conforms to Equatable, `replace(using:options:)`, `copy(to:)`, `init(dimensions:format:contents:)`
  - not iOS, not visionOS: `static generate(from:named:options:)`

### `TextureResource.Semantic` — enum (iOS 15.0); conforms to Codable
  - iOS 15.0: `.raw`, `.scalar`, `.color`, `.hdrColor`, `.normal`, conforms to Sendable, conforms to Equatable, conforms to Hashable

### `TextureResource.MipmapsMode` — enum (iOS 15.0); conforms to Codable
  - iOS 15.0: `.none`, `.allocateAll`, `.allocateAndGenerateAll`, conforms to Sendable, conforms to Equatable, conforms to Hashable

### `TextureResource.CreateOptions` — struct (iOS 15.0); conforms to Codable, Sendable
  - iOS 15.0: `semantic`, `mipmapsMode`, `init(semantic:mipmapsMode:)`
  - iOS 18.0, visionOS 2.0: `compression`, `init(semantic:compression:mipmapsMode:)`

### `TextureResource.Drawable` — class
  - unannotated: `drawableQueue`, `texture`, `present()`
  - visionOS 1.0: `presentOnSceneUpdate()`

### `TextureResource.DrawableQueue` — class (iOS 15.0)
  - iOS 15.0: `pixelFormat`, `width`, `height`, `usage`, `mipmapsMode`, `init(_:)`, `nextDrawable()`, `allowsNextDrawableTimeout`

### `TextureResource.DrawableQueue.Descriptor` — struct
  - iOS 15.0: `pixelFormat`, `width`, `height`, `usage`, `mipmapsMode`, `init(pixelFormat:width:height:usage:mipmapsMode:)`
  - iOS 18.0, visionOS 2.0: `timeout`, `init(pixelFormat:width:height:usage:mipmapsMode:timeout:)`
- extension of `MTLCommandBuffer`
  - iOS 15.0: `present(_:)`

### `TextureResource.Compression` — struct; conforms to Hashable, Sendable, Codable
  - iOS 18.0, visionOS 2.0: `static none`, `static default`
  - not iOS, not visionOS: `static astc(blockSize:quality:)`

### `TextureResource.Compression.ASTCBlockSize` — enum; conforms to Hashable, Sendable, Codable
  - iOS 18.0, visionOS 2.0: `.block4x4`, `.block5x4`, `.block5x5`, `.block6x5`, `.block6x6`, `.block8x5`, `.block8x6`, `.block8x8`, `.block10x5`, `.block10x6`, `.block10x8`, `.block10x10`, `.block12x10`, `.block12x12`

### `TextureResource.Compression.ASTCQuality` — enum; conforms to Hashable, Sendable, Codable
  - iOS 18.0, visionOS 2.0: `.fast`, `.normal`, `.high`, `.exhaustive`

### `RealityRenderer` — class (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `entities`, `subscribe(to:on:componentType:_:)`, `lighting`, `activeCamera`, `cameraSettings`, `init()`, `update(_:)`, `updateAndRender(deltaTime:cameraOutput:whenScheduled:onComplete:actionsBeforeRender:actionsAfterRender:)`
  - iOS 27.0, not visionOS: `audioListener`
  - not visionOS: `extendedDynamicRangeOutput`, `extendedDynamicRangeHeadroom`

### `RealityRenderer.EntityCollection` — struct; conforms to EntityCollection
  - iOS 18.0, visionOS 1.0: `startIndex`, `endIndex`, `count`, `subscript(index:)`, `index(after:)`, `insert(contentsOf:beforeIndex:)`, `append(contentsOf:)`, `remove(_:)`, `remove(at:)`, `removeAll()`, `replaceAll(_:)`, conforms to Sendable

### `RealityRenderer.CameraSettings` — struct
  - iOS 18.0, visionOS 1.0: `isToneMappingEnabled`, `colorBackground`
  - iOS 18.0, visionOS 2.0: `antialiasing`

### `RealityRenderer.CameraSettings.ColorBackground` — struct
  - iOS 18.0, visionOS 1.0: `static color(_:)`, `static outputTexture()`

### `RealityRenderer.CameraOutput` — struct
  - iOS 18.0, visionOS 1.0: `colorTextures`, `viewports`, `init(_:)`

### `RealityRenderer.CameraOutput.RelativeViewport` — struct
  - iOS 18.0, visionOS 1.0: `originX`, `originY`, `width`, `height`, `init(originX:originY:width:height:)`

### `RealityRenderer.CameraOutput.Descriptor` — struct
  - iOS 18.0, visionOS 1.0: `colorTextures`, `viewports`, `static singleProjection(colorTexture:)`

### `RealityRenderer.ImageBasedLight` — struct
  - iOS 18.0, visionOS 1.0: `resource`, `intensityExponent`

### `RealityRenderer.MetalEventAction` — struct
  - iOS 18.0, visionOS 1.0: `event`, `value`, `static wait(for:value:)`, `static signal(_:value:)`

### `PhysicsBodyComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `mode`, `massProperties`, `material`, `isTranslationLocked`, `isRotationLocked`, `isContinuousCollisionDetectionEnabled`, `init()`, `init(massProperties:material:mode:)`, `init(shapes:density:material:mode:)`, `init(shapes:mass:material:mode:)`
  - iOS 18.0, visionOS 1.0: `isAffectedByGravity`, `linearDamping`, `angularDamping`

### `EmphasizeAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `motionType`, `style`, `animatedValueType`, `isAdditive`, `init(motionType:style:isAdditive:)`

### `EmphasizeAction.EmphasisAnimationStyle` — enum; conforms to Int, Codable
  - iOS 18.0, visionOS 2.0: `.basic`, `.playful`, `.wild`, `init(rawValue:)`, `rawValue`, conforms to Equatable, conforms to Hashable, conforms to RawRepresentable

### `EmphasizeAction.EmphasisMotionType` — enum; conforms to Int, Codable
  - iOS 18.0, visionOS 2.0: `.pop`, `.blink`, `.bounce`, `.flip`, `.float`, `.jiggle`, `.pulse`, `.spin`, `init(rawValue:)`, `rawValue`, conforms to Equatable, conforms to Hashable, conforms to RawRepresentable

### `BillboardAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `transitionIn`, `transitionOut`, `animatedValueType`, `init(transitionIn:transitionOut:)`

### `BillboardAction.Transition` — struct; conforms to Codable
  - iOS 18.0, visionOS 2.0: `duration`, `timingFunction`, `init(duration:timingFunction:)`

### `PhysicsJoint` — protocol (iOS 18.0, visionOS 2.0); conforms to Equatable
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `addToSimulation()`

### `PhysicsFixedJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `init(pin0:pin1:)`

### `PhysicsSphericalJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `angularLimitInYZ`, `init(pin0:pin1:angularLimitInYZ:checksForInternalCollisions:)`

### `PhysicsRevoluteJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `angularLimit`, `init(pin0:pin1:angularLimit:checksForInternalCollisions:)`

### `PhysicsPrismaticJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `linearLimit`, `init(pin0:pin1:linearLimit:checksForInternalCollisions:)`

### `PhysicsDistanceJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `distanceLimit`, `tolerance`, `init(pin0:pin1:distanceLimit:checksForInternalCollisions:)`

### `PhysicsCustomJoint` — struct (iOS 18.0, visionOS 2.0); conforms to PhysicsJoint
  - iOS 18.0, visionOS 2.0: `pin0`, `pin1`, `checksForInternalCollisions`, `isActive`, `linearMotionAlongX`, `linearMotionAlongY`, `linearMotionAlongZ`, `angularMotionAroundX`, `angularMotionAroundY`, `angularMotionAroundZ`, `init(pin0:pin1:linearMotionAlongX:linearMotionAlongY:linearMotionAlongZ:angularMotionAroundX:angularMotionAroundY:angularMotionAroundZ:checksForInternalCollisions:)`

### `PhysicsCustomJoint.MotionLimit` — enum; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `.fixed`, `.unlimited`, `.range(...)`

### `PhysicsJoints` — struct (iOS 18.0, visionOS 2.0); conforms to BidirectionalCollection, MutableCollection, RangeReplaceableCollection, Equatable, ExpressibleByArrayLiteral
  - iOS 18.0, visionOS 2.0: `init()`, `init(arrayLiteral:)`, `init(_:)`, `startIndex`, `endIndex`, `index(before:)`, `index(after:)`, `count`, `subscript(index:)`, `replaceSubrange(_:with:)`

### `CustomMaterial` — struct (iOS 15.0, not visionOS); conforms to Material
  - iOS 18.0, not visionOS: `init(program:)`, `program`, `withMutableUniforms(ofType:stage:_:)`, `withMutableUniforms(ofType:_:)`, `triangleFillMode`, `writesDepth`, `readsDepth`, `clearcoatNormal`
  - iOS 15.0: `init(surfaceShader:geometryModifier:lightingModel:)`, `init(from:surfaceShader:geometryModifier:)`, `init(from:geometryModifier:)`, `lightingModel`, `baseColor`, `metallic`, `roughness`, `emissiveColor`, `specular`, `opacityThreshold`, `faceCulling`, `blending`, `normal`, `ambientOcclusion`, `clearcoat`, `clearcoatRoughness`, `textureCoordinateTransform`, `secondaryTextureCoordinateTransform`, `custom`
  - iOS 26.0, not visionOS: `static supportsMutableUniformsResources`

### `CustomMaterial.Program` — class; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, not visionOS: `surfaceShader`, `geometryModifier`, `descriptor`, `init(surfaceShader:geometryModifier:descriptor:)`

### `CustomMaterial.Program.Descriptor` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, not visionOS: `lightingModel`, `blendMode`, `init()`

### `EnvironmentLightingConfigurationComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 2.0: `environmentLightingWeight`, `init(environmentLightingWeight:)`

### `AudioPlaybackController` — class
  - unannotated: `entity`, `resource`, `completionHandler`
  - iOS 13.0: `speed`, `gain`, `fade(to:duration:)`, `isPlaying`, `play()`, `pause()`, `stop()`, conforms to Identifiable, `id`, conforms to Sendable
  - not visionOS, deprecated: `reverbSendLevel`
  - iOS 18.0, visionOS 1.0: `seek(to:)`
  - iOS 27.0, visionOS 27.0: `play(at:)`

### `RealityCoordinateSpace` — protocol (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `static scene`
  - iOS 18.0, not visionOS: `static camera`

### `SceneRealityCoordinateSpace` — struct (iOS 18.0, visionOS 1.0); conforms to RealityCoordinateSpace
  - iOS 18.0, visionOS 1.0: `init()`

### `CameraRealityCoordinateSpace` — struct (iOS 18.0, not visionOS); conforms to RealityCoordinateSpace
  - iOS 18.0, not visionOS: `init()`

### `LowLevelBuffer` — class (iOS 26.0, visionOS 26.0)
  - iOS 26.0, visionOS 26.0: `descriptor`, `bytesUsed`, `init(descriptor:)`, `withUnsafeBytes(_:)`, `withUnsafeMutableBytes(_:)`, `replaceUnsafeMutableBytes(_:)`, `read(using:)`, `replace(using:)`

### `LowLevelBuffer.Descriptor` — struct; conforms to Sendable
  - iOS 26.0, visionOS 26.0: `capacity`, `sizeMultiple`, `init(capacity:sizeMultiple:)`

### `DiffuseLightProbeGroupComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `resource`, `init(resource:)`

### `CustomMaterial.GeometryModifier` — struct (iOS 15.0); conforms to MaterialFunction
  - iOS 18.0, not visionOS: `constantValues`, `init(named:in:constantValues:)`
  - iOS 15.0: `name`, `library`, `init(named:in:)`

### `CustomMaterial.SurfaceShader` — struct (iOS 15.0); conforms to MaterialFunction
  - iOS 18.0, not visionOS: `constantValues`, `init(named:in:constantValues:)`
  - iOS 15.0: `name`, `library`, `init(named:in:)`

### `PlayAnimationAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `animationName`, `transitionDuration`, `blendLayer`, `separateAnimatedValue`, `handoffType`, `targetEntity`, `useParentedControllers`, `animatedValueType`, `init(animationName:targetEntity:transitionDuration:blendLayer:separateAnimatedValue:useParentedControllers:handoffType:)`

### `Audio.Scattering` — struct; conforms to Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `init(_:)`, `static default`, `static uniform(_:)`, `scaled(by:)`, conforms to ExpressibleByDictionaryLiteral, `init(dictionaryLiteral:)`

### `Entity.ComponentSet` — struct
  - iOS 18.0, visionOS 2.0: conforms to Sequence, conforms to Collection, `startIndex`, `endIndex`, `isEmpty`, `index(after:)`, `formIndex(after:)`, `distance(from:to:)`, `subscript(position:)`, `indices`
  - iOS 26.0, visionOS 26.0: conforms to BidirectionalCollection, `index(before:)`, `set(_:)`
  - iOS 27.0, visionOS 27.0: `set(qualifiedComponentName:representation:)`
  - iOS 13.0: `subscript(componentType:backDeploy:)`, `entity`, conforms to Sendable

### `Entity.ComponentSet.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `Entity.ComponentSet.Index` — struct; conforms to Comparable, Sendable

### `Entity.ComponentSet.Indices` — struct; conforms to Collection, Sendable
  - iOS 18.0, visionOS 2.0: `startIndex`, `endIndex`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`, `distance(from:to:)`, `subscript(bounds:)`, `indices`
  - iOS 26.0, visionOS 26.0: conforms to BidirectionalCollection, `index(before:)`

### `HasSynchronization` — protocol (iOS 13.0); conforms to Entity
  - iOS 13.0: `synchronization`, `isOwner`, `requestOwnership(timeout:_:)`, `withUnsynchronized(_:)`

### `SynchronizationComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `identifier`, `isOwner`, `ownershipTransferMode`, `init()`

### `SynchronizationComponent.OwnershipTransferMode` — enum
  - iOS 13.0: `.autoAccept`, `.manual`, conforms to Equatable, conforms to Hashable

### `SynchronizationComponent.OwnershipTransferCompletionResult` — enum
  - iOS 13.0: `.granted`, `.timedOut`, conforms to Equatable, conforms to Hashable

### `OrbitEntityAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `pivotEntity`, `revolutions`, `orbitalAxis`, `isOrientedToPath`, `animatedValueType`, `isAdditive`, `init(pivotEntity:revolutions:orbitalAxis:isOrientedToPath:isAdditive:)`

### `BlendWeight` — enum (iOS 15.0); conforms to Equatable
  - iOS 15.0: `.value(...)`, `.parameter(...)`, `.bindTarget(...)`

### `BlendTreeNode` — protocol (iOS 15.0)
  - iOS 15.0: `name`, `weight`

### `BlendTreeSourceNode` — struct (iOS 15.0); conforms to BlendTreeNode
  - iOS 15.0: `init(source:name:weight:)`, `source`, `name`, `weight`

### `BlendTreeBlendNode` — struct (iOS 15.0); conforms to BlendTreeNode
  - iOS 15.0: `init(sources:name:weight:isAdditive:)`, `sources`, `isAdditive`, `name`, `weight`

### `BlendTreeInvalidNode` — struct (iOS 15.0); conforms to BlendTreeNode
  - iOS 15.0: `name`, `weight`

### `BlendTreeAnimation` — struct (iOS 15.0); conforms to AnimationDefinition where Value : AnimatableData
  - iOS 15.0: `init(_:name:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `root`, `name`, `blendLayer`, `bindTarget`, `fillMode`, `isAdditive`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`

### `ImagePresentationComponent` — struct (not iOS, visionOS 26.0); conforms to Component
  - not iOS, visionOS 26.0: `aspectRatio(for:)`, `screenHeight`, `presentationScreenSize`, `screenImageDimension`, `desiredViewingMode`, `viewingMode`, `availableViewingModes`, `static supportedViewingModes(for:)`, `init(imageSource:)`, `init(contentsOf:)`, `init(spatial3DImage:)`

### `ImagePresentationComponent.Spatial3DImage` — class
  - not iOS, visionOS 26.0: `init(imageSource:)`, `init(contentsOf:)`

### `QueryResult` — struct (iOS 15.0)
  - iOS 15.0: conforms to Sequence, `makeIterator()`

### `QueryResult.Iterator` — struct (iOS 15.0); conforms to IteratorProtocol
  - iOS 15.0: `next()`

### `PhotogrammetrySample` — struct (iOS 17.0, not visionOS); conforms to Identifiable
  - iOS 17.0, not visionOS: `id`, `image`, `metadata`, `depthDataMap`, `gravity`, `objectMask`, `init(id:image:)`
  - iOS 18.0, not visionOS: conforms to CustomStringConvertible, `description`, `init(contentsOf:)`, `captureTime`, `boundingBox`, `depthConfidenceMap`, `camera`, `sessionID`, `scanPassID`
  - iOS 26.0, not visionOS: `orientation`

### `PhotogrammetrySample.Camera` — struct (iOS 18.0, not visionOS)
  - iOS 18.0, not visionOS: `id`, `intrinsics`, `transform`, `calibrationData`

### `CustomMaterial.CustomMaterialTexture` — struct (iOS 15.0)
  - iOS 15.0: `resource`, `init(_:)`
  - iOS 18.0, not visionOS: `swizzle`, `init(_:_:)`

### `CustomMaterial.BaseColor` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `init(_:)`

### `CustomMaterial.Metallic` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.Roughness` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.EmissiveColor` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `init(_:)`

### `CustomMaterial.Specular` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.Blending` — enum (iOS 15.0); conforms to Hashable
  - iOS 15.0: `.opaque`, `.transparent(...)`, `init(blending:)`

### `CustomMaterial.Opacity` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral, Hashable
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.Clearcoat` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.ClearcoatRoughness` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `init(scale:texture:)`, `init(floatLiteral:)`, `init(_:)`

### `CustomMaterial.Normal` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `init(texture:)`, `init(_:)`

### `CustomMaterial.AmbientOcclusion` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `init(texture:)`, `init(_:)`

### `CustomMaterial.ClearcoatNormal` — struct
  - iOS 18.0, not visionOS: `texture`, `init(texture:)`, `init(_:)`

### `AudioFileGroupResource` — class; conforms to AudioResource
  - iOS 18.0, visionOS 1.0: `static load(named:from:in:)`, conforms to Hashable
  - unannotated: `resources`, `init(named:from:in:)`, `init(_:)`

### `AnimationGroup` — struct (iOS 15.0); conforms to AnimationDefinition
  - iOS 15.0: `group`, `name`, `blendLayer`, `bindTarget`, `fillMode`, `additive`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`, `init(group:name:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`
  - deprecated: `group_`

### `AudioBufferResource` — class; conforms to AudioResource
  - iOS 18.0, visionOS 1.0: `configuration`, `init(buffer:configuration:)`, conforms to Hashable, `duration`
  - deprecated: `shouldLoop`
  - not visionOS, deprecated: `init(buffer:inputMode:shouldLoop:)`

### `AudioBufferResource.Configuration` — struct
  - iOS 18.0, visionOS 1.0: `shouldLoop`, `shouldRandomizeStartTime`, `normalization`, `calibration`, `mixGroupName`, `init(shouldLoop:shouldRandomizeStartTime:normalization:calibration:mixGroupName:)`, conforms to Equatable, Hashable, Sendable

### `Material` — protocol (iOS 13.0)
  - iOS 18.0, visionOS 1.0: `name`

### `SimpleMaterial` — struct (iOS 13.0); conforms to Material
  - iOS 15.0: `color`
  - iOS 13.0: `roughness`, `metallic`, `init()`
  - iOS 18.0, visionOS 1.0: `triangleFillMode`
  - iOS 18.0, visionOS 2.0: `writesDepth`, `readsDepth`, `faceCulling`

### `OcclusionMaterial` — struct (iOS 13.0); conforms to Material, Sendable
  - visionOS 2.0: `receivesDynamicLighting`, `init(receivesDynamicLighting:)`
  - not iOS, visionOS 1.0: `init()`
  - iOS 18.0, visionOS 2.0: `readsDepth`, `faceCulling`

### `VideoMaterial` — struct (iOS 14.0); conforms to Material
  - iOS 14.0: `init(avPlayer:)`, `avPlayer`, `controller`
  - iOS 18.0, visionOS 1.0: `triangleFillMode`
  - iOS 18.0, visionOS 2.0: `writesDepth`, `readsDepth`, `faceCulling`, `videoRenderer`, `init(videoRenderer:)`

### `MaterialScalarParameter` — enum (iOS 13.0); conforms to ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, Hashable
  - iOS 13.0: `.float(...)`, `.texture(...)`, `init(floatLiteral:)`, `init(integerLiteral:)`

### `PortalMaterial` — struct (iOS 18.0, visionOS 1.0); conforms to Material, Sendable
  - iOS 18.0, visionOS 1.0: `init()`, `triangleFillMode`
  - iOS 18.0, visionOS 2.0: `faceCulling`
  - iOS 27.0, visionOS 27.0: `program`, `init(program:)`, `static parameterHandle(name:)`, `setParameter(handle:value:)`, `getParameter(handle:)`, `setParameter(name:value:)`, `getParameter(name:)`

### `LensDistortionData` — struct (iOS 26.0, not visionOS); conforms to Sendable
  - iOS 26.0, not visionOS: `center`, `radialLookupTable`, `init(center:radialLookupTable:)`

### `PortalComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `targetEntity`, `clippingPlane`, `init(target:clippingPlane:)`
  - iOS 18.0, visionOS 2.0: `clippingMode`, `crossingMode`, `init(target:clippingMode:crossingMode:)`, `init(target:plane:options:)`
  - iOS 27.0, visionOS 27.0: `lightingBlendDistance`, `static configure(world:portalEntity:surfaceStyle:boundaryStyle:boundaryMode:)`, `static makePortal(surfaceStyle:boundaryStyle:boundaryMode:)`

### `PortalComponent.ClippingPlane` — struct
  - iOS 18.0, visionOS 1.0: `position`, `normal`, `init(position:normal:)`

### `PortalComponent.Volume` — struct; conforms to Equatable
  - iOS 27.0, visionOS 27.0: `position`, `extents`, `init(position:extents:)`

### `PortalComponent.Plane` — struct; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `position`, `normal`, `init(position:normal:)`, `static positiveX`, `static negativeX`, `static positiveY`, `static negativeY`, `static positiveZ`, `static negativeZ`

### `PortalComponent.ClippingMode` — enum; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `.disabled`, `.plane(...)`
  - iOS 27.0, visionOS 27.0: `.volume(...)`

### `PortalComponent.CrossingMode` — enum; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `.disabled`, `.plane(...)`
  - iOS 27.0, visionOS 27.0: `.volume(...)`

### `PortalComponent.Options` — struct; conforms to OptionSet
  - iOS 18.0, visionOS 2.0: `init(rawValue:)`, `rawValue`, `static clipContents`, `static allowCrossing`

### `AdaptiveResolutionComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `init()`, `pixelsPerMeter`

### `SpotLightComponent` — struct (iOS 13.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 13.0, visionOS 2.0: `intensity`, `innerAngleInDegrees`, `outerAngleInDegrees`, `attenuationRadius`
  - iOS 18.0, visionOS 2.0: `attenuationFalloffExponent`
  - iOS 27.0, visionOS 27.0: `layers`

### `SpotLightComponent.Shadow` — struct; conforms to Component, Equatable
  - iOS 13.0, visionOS 2.0: `init()`
  - iOS 18.0, visionOS 2.0: `depthBias`, `cullModeOverride`, `zNear`, `zFar`
  - iOS 27.0, visionOS 27.0: `layers`, `init(layers:)`, `lightSize`, `quality`

### `SpotLightComponent.ProjectiveTexture` — struct; conforms to Component
  - iOS 27.0, visionOS 27.0: `coordinateTransform`, `texture`, `init(texture:)`, `init(texture:scale:)`, `init(texture:coordinateTransform:)`

### `SpotLightComponent.Shadow.ShadowClippingPlane` — enum; conforms to Equatable
  - iOS 18.0, visionOS 2.0: `.automatic`, `.fixed(...)`

### `SpotLightComponent.SurroundingsLight` — struct (not iOS, visionOS 27.0); conforms to Component, Equatable
  - not iOS, visionOS 27.0: `init()`

### `SpotLightComponent.Shadow.QualityMode` — struct (iOS 27.0, visionOS 27.0); conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `rawValue`, `init(rawValue:)`, `static low`, `static medium`, `static high`

### `AudioMixGroupsComponent` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `init(mixGroups:)`, `set(_:)`, `remove(named:)`, `mixGroup(named:)`, conforms to Hashable, conforms to Component

### `AnimationView` — struct (iOS 15.0); conforms to AnimationDefinition
  - unannotated: `init(name:source:targetPath:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`
  - iOS 15.0: `name`, `blendLayer`, `fillMode`, `bindTarget`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `source`, `duration`, `init(source:name:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`

### `OrbitAnimation` — struct (iOS 15.0); conforms to AnimationDefinition
  - unannotated: `init(name:duration:axis:startTransform:spinClockwise:orientToPath:rotationCount:additive:targetPath:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`
  - iOS 15.0: `name`, `blendLayer`, `bindTarget`, `fillMode`, `additive`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`, `axis`, `startTransform`, `spinClockwise`, `orientToPath`, `rotationCount`, `init(name:duration:axis:startTransform:spinClockwise:orientToPath:rotationCount:bindTarget:blendLayer:repeatMode:fillMode:isAdditive:trimStart:trimEnd:trimDuration:offset:delay:speed:)`

### `IKSolverDefinition` — struct (iOS 18.0, visionOS 2.0); conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `rigDefinition`, `init(id:rig:)`

### `IKRig` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `maxIterations`, `globalFkWeight`, `globalLimitsWeight`, `joints`, `constraints`, `init(for:)`
  - iOS 27.0, visionOS 27.0: `init(named:rootJoint:)`

### `IKRig.Joint` — struct; conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `init(name:parentID:restTransform:)`, `id`, `name`, `parentID`, `restTransform`, `active`, `fkWeightPerAxis`, `rotationStiffness`, `limits`

### `IKRig.Joint.ID` — struct; conforms to Hashable, Equatable

### `IKRig.Joint.LimitsDefinition` — struct
  - iOS 18.0, visionOS 2.0: `weight`, `boneAxis`, `minimumAngles`, `maximumAngles`, `init(weight:boneAxis:minimumAngles:maximumAngles:)`

### `IKRig.Joint.LimitsDefinition.Axis` — enum
  - iOS 18.0, visionOS 2.0: `.x`, `.y`, `.z`, conforms to Equatable, conforms to Hashable

### `IKRig.Constraint` — struct; conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `name`, `jointName`, `offset`, `positionDemand`, `orientationDemand`, `static point(named:on:positionWeight:)`, `static orient(named:on:orientationWeight:)`, `static parent(named:on:positionWeight:orientationWeight:)`, `static lookAtAdditive(named:on:lookingAlong:orientationWeight:)`, `static lookAtAbsolute(named:on:lookingAlong:orientationWeight:)`

### `IKRig.Constraint.ID` — struct; conforms to Hashable, Equatable

### `IKRig.Constraint.IKPositionDemand` — struct
  - iOS 18.0, visionOS 2.0: `init()`, `mode`, `influenceDepthMaxJointCount`, `weight`

### `IKRig.Constraint.IKPositionDemand.Mode` — enum
  - iOS 18.0, visionOS 2.0: `.reach`, `.poleVector`, conforms to Equatable, conforms to Hashable

### `IKRig.Constraint.IKOrientationDemand` — struct
  - iOS 18.0, visionOS 2.0: `init()`, `mode`, `influenceDepthMaxJointCount`, `weight`

### `IKRig.Constraint.IKOrientationDemand.Mode` — enum
  - iOS 18.0, visionOS 2.0: `.orientation`, `.additiveLookAt(...)`, `.absoluteLookAt(...)`

### `IKRig.JointCollection` — struct; conforms to Collection, Sequence
  - iOS 18.0, visionOS 2.0: `subscript(id:)`, `subscript(name:)`, `forEach(descendantOf:inclusive:update:)`, `count`, `isEmpty`, `contains(_:)`, `set(_:)`, `startIndex`, `endIndex`, `subscript(position:)`, `index(after:)`

### `IKRig.JointCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `IKRig.ConstraintsCollection` — struct; conforms to Collection, Sequence, ExpressibleByArrayLiteral
  - iOS 18.0, visionOS 2.0: `init(_:)`, `subscript(name:)`, `subscript(id:)`, `count`, `isEmpty`, `contains(_:)`, `set(_:)`, `startIndex`, `endIndex`, `subscript(position:)`, `index(after:)`, `init(arrayLiteral:)`

### `IKRig.ConstraintsCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `ImpulseAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `targetEntity`, `linearImpulse`, `animatedValueType`, `init(targetEntity:linearImpulse:)`

### `TweenMode` — enum (iOS 15.0)
  - iOS 15.0: `.hold`, `.linear`, conforms to Equatable, conforms to Hashable

### `SampledAnimation` — struct (iOS 15.0); conforms to AnimationDefinition where Value : AnimatableData
  - iOS 15.0: `name`, `blendLayer`, `bindTarget`, `fillMode`, `additive`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `tweenMode`, `frameInterval`, `start`, `end`, `duration`, `init(frames:name:tweenMode:frameInterval:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `frames`, `init(jointNames:frames:name:tweenMode:frameInterval:isAdditive:isScaleAnimated:isRotationAnimated:isTranslationAnimated:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `isScaleAnimated`, `isRotationAnimated`, `isTranslationAnimated`, `jointNames`
  - iOS 27.0, visionOS 27.0: `processAndCreateAnimation(for:operations:name:)`, `processAndCreateAnimation(retargeting:operations:name:)`
  - iOS 18.0, visionOS 2.0: `init(weightNames:frames:name:tweenMode:frameInterval:isAdditive:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `frames`, `weightNames`

### `SampledAnimation.SkeletalAnimationOperation` — struct
  - iOS 27.0, visionOS 27.0: `static extractRootMotion(jointName:options:lockPosition:)`, `static removeAnimation(for:)`, `static convertToAdditive(baseAnimation:)`, `static convertToAdditiveUsingRestPose()`, `static convertToAdditiveUsingFirstSample()`

### `SampledAnimation.SkeletalAnimationOperation.RootMotionOptions` — struct; conforms to OptionSet
  - iOS 27.0, visionOS 27.0: `rawValue`, `init(rawValue:)`, `static translationX`, `static translationY`, `static translationZ`, `static rotationX`, `static rotationY`, `static rotationZ`, `static translationXZ`, `static extractAll`

### `FromToByAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable where Value : AnimatableData
  - iOS 18.0, visionOS 2.0: `from`, `to`, `by`, `timingFunction`, `isAdditive`, `init(from:to:timing:isAdditive:)`, `init(from:by:timing:isAdditive:)`, `init(from:timing:isAdditive:)`, `init(to:by:timing:isAdditive:)`, `isReversible`, `animatedValueType`, `mode`, `init(from:to:mode:timing:isAdditive:)`, `init(from:by:mode:timing:isAdditive:)`, `init(to:by:mode:timing:isAdditive:)`, `init(by:timing:isAdditive:)`

### `FromToByAction.TransformMode` — enum; conforms to Equatable, Codable
  - iOS 18.0, visionOS 2.0: `.parent`, `.local`, `.scene`, `.relative(...)`, `static default`

### `FromToByAction.DecodingErrors` — enum; conforms to Error
  - iOS 18.0, visionOS 2.0: `.unsupportedValueType`, conforms to Equatable, conforms to Hashable

### `AnimationTimingFunction` — struct (iOS 13.0); conforms to Hashable
  - iOS 13.0: `static default`, `static linear`, `static easeIn`, `static easeOut`, `static easeInOut`, `static cubicBezier(controlPoint1:controlPoint2:)`
  - iOS 18.0, visionOS 2.0: conforms to Codable

### `Resource` — protocol (iOS 13.0); conforms to Sendable

### `HoverEffectComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `hoverEffect`, `init(_:)`
  - iOS 18.0, visionOS 1.0: `init()`

### `HoverEffectComponent.HoverEffect` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `static spotlight(_:)`, `static highlight(_:)`, `static shader(_:)`
  - iOS 26.0, visionOS 26.0: `groupID`, `static spotlight(_:groupID:)`, `static highlight(_:groupID:)`, `static shader(_:groupID:)`

### `HoverEffectComponent.OpacityFunction` — enum (iOS 18.0, visionOS 2.0); conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `.full`, `.mask`, `.blend`

### `HoverEffectComponent.SpotlightHoverEffectStyle` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable
  - iOS 18.0, visionOS 2.0: `static default`, `strength`, `opacityFunction`

### `HoverEffectComponent.HighlightHoverEffectStyle` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable
  - iOS 18.0, visionOS 2.0: `static default`, `strength`, `opacityFunction`

### `HoverEffectComponent.ShaderHoverEffectInputs` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable
  - iOS 18.0, visionOS 2.0: `static default`, `fadeInDuration`, `fadeOutDuration`, `init(fadeInDuration:fadeOutDuration:)`

### `HoverEffectComponent.GroupID` — struct; conforms to Hashable, Sendable
  - iOS 26.0, visionOS 26.0: `init()`

### `SkeletalPosesComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `poses`, `init(poses:)`

### `PhysicallyBasedMaterial` — struct (iOS 15.0); conforms to Material
  - iOS 15.0: `init()`, `baseColor`, `metallic`, `roughness`, `emissiveColor`, `emissiveIntensity`, `specular`, `clearcoat`, `clearcoatRoughness`, `opacityThreshold`, `faceCulling`, `blending`, `normal`, `ambientOcclusion`, `anisotropyLevel`, `anisotropyAngle`, `sheen`, `textureCoordinateTransform`, `secondaryTextureCoordinateTransform`
  - iOS 18.0, visionOS 1.0: `triangleFillMode`
  - iOS 18.0, visionOS 2.0: `writesDepth`, `readsDepth`, `program`, `init(program:)`, `clearcoatNormal`
  - iOS 27.0, visionOS 27.0: `subsurfaceWeight`, `subsurfaceColor`, `subsurfaceRadius`, `subsurfaceRadiusScale`, `subsurfaceScatterAnisotropy`, `bentNormal`, `enableSpecularOcclusion`

### `PhysicallyBasedMaterial.BaseColor` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `static textureSemantic`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Metallic` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Roughness` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.EmissiveColor` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `static textureSemantic`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Specular` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Blending` — enum (iOS 15.0); conforms to Hashable
  - iOS 15.0: `.opaque`, `.transparent(...)`
  - not visionOS: `init(blending:)`

### `PhysicallyBasedMaterial.Opacity` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral, Hashable
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Clearcoat` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.ClearcoatRoughness` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.Normal` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `static textureSemantic`, `init(texture:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.AmbientOcclusion` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `static textureSemantic`, `init(texture:)`
  - not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.AnisotropyLevel` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`

### `PhysicallyBasedMaterial.AnisotropyAngle` — struct (iOS 15.0); conforms to ExpressibleByFloatLiteral
  - iOS 15.0: `scale`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`

### `PhysicallyBasedMaterial.SheenColor` — struct (iOS 15.0)
  - iOS 15.0: `texture`, `static textureSemantic`

### `PhysicallyBasedMaterial.Program` — class; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `descriptor`, `init(descriptor:)`

### `PhysicallyBasedMaterial.Program.Descriptor` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `blendMode`, `init()`

### `PhysicallyBasedMaterial.ClearcoatNormal` — struct
  - iOS 18.0, visionOS 2.0: `texture`, `static textureSemantic`, `init(texture:)`
  - iOS 18.0, not visionOS: `init(_:)`

### `PhysicallyBasedMaterial.SubsurfaceWeight` — struct; conforms to ExpressibleByFloatLiteral
  - iOS 27.0, visionOS 27.0: `static scaleKey`, `scale`, `static textureKey`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`

### `PhysicallyBasedMaterial.SubsurfaceColor` — struct
  - iOS 27.0, visionOS 27.0: `static colorKey`, `color`, `static textureKey`, `texture`, `static textureSemantic`, `init(color:texture:)`

### `PhysicallyBasedMaterial.SubsurfaceRadius` — struct; conforms to ExpressibleByFloatLiteral
  - iOS 27.0, visionOS 27.0: `static scaleKey`, `scale`, `static textureKey`, `texture`, `static textureSemantic`, `init(scale:texture:)`, `init(floatLiteral:)`

### `PhysicallyBasedMaterial.SubsurfaceRadiusScale` — struct
  - iOS 27.0, visionOS 27.0: `static colorKey`, `color`, `static textureKey`, `texture`, `static textureSemantic`, `init(color:texture:)`

### `PhysicallyBasedMaterial.SubsurfaceScatterAnisotropy` — struct; conforms to ExpressibleByFloatLiteral
  - iOS 27.0, visionOS 27.0: `static scaleKey`, `scale`, `static textureKey`, `texture`, `static textureSemantic`, `init(texture:)`, `init(floatLiteral:)`

### `PhysicallyBasedMaterial.BentNormal` — struct
  - iOS 27.0, visionOS 27.0: `static textureKey`, `texture`, `static textureSemantic`, `init(texture:)`

### `AnchorEntity` — class; conforms to Entity, HasAnchoring
  - unannotated: `init()`, `init(world:)`
  - iOS 13.0: `init(_:)`, `init(plane:classification:minimumBounds:)`
  - iOS 18.0, visionOS 1.0: `init(_:trackingMode:)`
  - iOS 18.0, visionOS 2.0: `init(_:trackingMode:physicsSimulation:)`

### `BodyTrackedEntity` — class (not visionOS); conforms to Entity, HasBodyTracking, HasModel

### `PerspectiveCamera` — class; conforms to Entity, HasPerspectiveCamera
  - unannotated: `init()`

### `SpotLight` — class; conforms to Entity, HasSpotLight
  - unannotated: `init()`

### `DirectionalLight` — class; conforms to Entity, HasDirectionalLight
  - unannotated: `init()`

### `PointLight` — class; conforms to Entity, HasPointLight
  - unannotated: `init()`

### `ModelEntity` — class; conforms to Entity, HasModel, HasPhysics
  - unannotated: `init()`, `init(mesh:materials:)`, `init(mesh:materials:collisionShape:mass:)`, `init(mesh:materials:collisionShapes:mass:)`

### `TriggerVolume` — class (iOS 13.0); conforms to Entity, HasCollision
  - iOS 13.0: `init()`, `init(shape:filter:)`, `init(shapes:filter:)`

### `PointLightComponent` — struct (iOS 13.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 13.0, visionOS 2.0: `intensity`, `attenuationRadius`, `init(cgColor:intensity:attenuationRadius:)`
  - iOS 18.0, visionOS 2.0: `attenuationFalloffExponent`
  - iOS 27.0, visionOS 27.0: `layers`

### `PointLightComponent.SurroundingsLight` — struct (not iOS, visionOS 27.0); conforms to Component, Equatable
  - not iOS, visionOS 27.0: `init()`

### `WorldComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `init()`

### `HasTransform` — protocol (iOS 13.0); conforms to Entity
  - iOS 13.0: `transform`, `scale`, `scale(relativeTo:)`, `setScale(_:relativeTo:)`, `position`, `position(relativeTo:)`, `setPosition(_:relativeTo:)`, `orientation`, `orientation(relativeTo:)`, `setOrientation(_:relativeTo:)`, `transformMatrix(relativeTo:)`, `setTransformMatrix(_:relativeTo:)`, `convert(position:from:)`, `convert(direction:from:)`, `convert(normal:from:)`, `convert(transform:from:)`, `convert(position:to:)`, `convert(direction:to:)`, `convert(normal:to:)`, `convert(transform:to:)`, `look(at:from:upVector:relativeTo:)`, `move(to:relativeTo:)`, `move(to:relativeTo:duration:timingFunction:)`, `visualBounds(recursive:relativeTo:excludeInactive:)`
  - iOS 18.0, visionOS 1.0: `look(at:from:upVector:relativeTo:forward:)`
  - iOS 18.0, visionOS 2.0: `align(_:to:)`

### `ActionResult` — enum (iOS 27.0, visionOS 27.0); conforms to Sendable
  - iOS 27.0, visionOS 27.0: `.running`, `.failure`, `.success`, conforms to Equatable, conforms to Hashable

### `ActionEvent` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction
  - iOS 18.0, visionOS 2.0: `playbackController`, `action`, `parameter`, `animationState`, `targetEntity`, `reversed`, `startTime`, `duration`
  - iOS 27.0, visionOS 27.0: conforms to BehaviorTreeAction, `entity`

### `ActionEventType` — struct (iOS 18.0, visionOS 2.0); conforms to OptionSet, Hashable
  - iOS 18.0, visionOS 2.0: `static started`, `static updated`, `static ended`, `static skipped`, `static paused`, `static resumed`, `static terminated`, `init(rawValue:)`, `rawValue`

### `ActionHandlerProtocol` — protocol (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `assoc ActionType`, `actionStarted(event:)`, `actionUpdated(event:)`, `actionEnded(event:)`, `actionSkipped(event:)`, `actionPaused(event:)`, `actionResumed(event:)`, `actionTerminated(event:)`, `static register(_:)`, conforms to Decodable, Self.ActionType : Encodable, Self.ActionType.EventParameterType : Decodable, Self.ActionType.EventParameterTy

### `EntityAction` — protocol (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `assoc EventParameterType`, `isReversible`, `isAdditive`, `animatedValueType`, `static registerAction()`, `static subscribe(to:_:)`, `static unsubscribe(from:)`, `static unsubscribeAll()`, conforms to Decodable, Self : Encodable, Self.EventParameterType : Decodable, Self.EventParameterType : Encodable

### `ActionEventDefinition` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction
  - iOS 18.0, visionOS 2.0: `init(startTime:duration:parameter:)`, `startTime`, `duration`, `parameter`

### `ActionAnimation` — struct (iOS 18.0, visionOS 2.0); conforms to AnimationDefinition where ActionType : EntityAction
  - iOS 18.0, visionOS 2.0: `name`, `blendLayer`, `bindTarget`, `fillMode`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`, `init(for:events:name:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`, `action`, `eventDefinitions`

### `AudioMixGroup` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `name`, `gain`, `speed`, `isMuted`, `init(name:)`, `fade(to:duration:)`, conforms to Equatable, conforms to Hashable

### `DockingRegionComponent` — struct (not iOS, visionOS 2.0); conforms to Component
  - not iOS, visionOS 2.0: `width`, `init()`

### `SpatialAudioComponent` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `gain`, `directLevel`, `reverbLevel`, `directivity`, `init(gain:directLevel:reverbLevel:directivity:)`, conforms to Component, conforms to Equatable, Hashable, Codable
  - iOS 18.0, visionOS 2.0: `init(gain:directLevel:reverbLevel:directivity:distanceAttenuation:)`, `distanceAttenuation`

### `BloomComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init()`, `init(scope:)`, `scope`

### `BloomComponent.BloomScope` — struct; conforms to Sendable, Equatable
  - iOS 27.0, visionOS 27.0: `static hierarchical`, `static unbounded`

### `BloomOptionsComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init()`, `strength`, `threshold`, `blurRadius`

### `OpacityComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 1.0: `opacity`, `init(opacity:)`

### `MeshDeformationStack` — struct (iOS 27.0, visionOS 27.0); conforms to Sendable, Equatable, Codable
  - iOS 27.0, visionOS 27.0: `deformers`, `targets`, `init()`, `init(deformers:targets:)`

### `ProjectiveTransformCameraComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 2.0: `transform`, `init(projectionMatrix:)`

### `VideoPlaybackController` — class
  - not visionOS, deprecated: `audioInputMode`, `reverbSendLevel`
  - iOS 18.0, visionOS 1.0: `preferredViewingMode`, `currentViewingMode`, `currentImageSize`
  - iOS 14.0: conforms to Sendable

### `VideoPlaybackController.ViewingMode` — enum; conforms to Sendable
  - iOS 18.0, visionOS 1.0: `.mono`, conforms to Equatable, conforms to Hashable
  - not iOS, visionOS 1.0: `.stereo`

### `AnimationGraphComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `graph`, `activeNodes`, `activeStateMachineNodes`, `activeClipNodes`, `activeTags`, `init(graph:)`

### `AnimationGraphComponent.ActiveNode` — protocol; conforms to Identifiable, Sendable
  - iOS 27.0, visionOS 27.0: `id`, `name`, `wasReset`

### `AnimationGraphComponent.ActiveStateMachineNode` — struct; conforms to AnimationGraphComponent.ActiveNode, Equatable, Sendable
  - iOS 27.0, visionOS 27.0: `id`, `name`, `wasReset`, `currentState`, `previousState`, `lastTransition`

### `AnimationGraphComponent.ActiveClipNode` — struct; conforms to AnimationGraphComponent.ActiveNode, Equatable, Sendable
  - iOS 27.0, visionOS 27.0: `id`, `name`, `wasReset`, `currentCycle`

### `AnimationGraphComponent.ActiveTag` — struct; conforms to Equatable, Identifiable, Sendable
  - iOS 27.0, visionOS 27.0: `id`, `name`

### `ManipulationComponent` — struct (not iOS, visionOS 26.0); conforms to Component
  - not iOS, visionOS 26.0: `init()`, `dynamics`, `releaseBehavior`, `audioConfiguration`, `static configureEntity(_:hoverEffect:allowedInputTypes:collisionShapes:)`

### `ManipulationComponent.ReleaseBehavior` — struct; conforms to Equatable, Sendable
  - not iOS, visionOS 26.0: `static reset`, `static stay`

### `ManipulationComponent.AudioConfiguration` — struct; conforms to Equatable, Sendable
  - not iOS, visionOS 26.0: `static default`, `static none`

### `ManipulationComponent.HitTarget` — struct; conforms to Component
  - not iOS, visionOS 26.0: `redirectedEntity`, `init(redirectedEntity:)`

### `ManipulationComponent.InputDevice` — struct; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `chirality`, `kind`, `pose`

### `ManipulationComponent.InputDevice.Chirality` — enum; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `.left`, `.right`

### `ManipulationComponent.InputDevice.Kind` — enum; conforms to Int, Hashable, Sendable
  - not iOS, visionOS 26.0: `.indirectPinch`, `.directPinch`, `.pointer`, `init(rawValue:)`, `rawValue`, conforms to RawRepresentable

### `ManipulationComponent.InputDevice.Kind.Set` — struct; conforms to OptionSet, Hashable, Sendable
  - not iOS, visionOS 26.0: `rawValue`, `init(rawValue:)`, `init(_:)`, `static indirectPinch`, `static directPinch`, `static pointer`, `static all`

### `ManipulationComponent.Dynamics` — struct; conforms to Sendable
  - not iOS, visionOS 26.0: `inertia`, `scalingBehavior`, `secondaryRotationBehavior`, `primaryRotationBehavior`, `translationBehavior`, `init()`

### `ManipulationComponent.Dynamics.TranslationBehavior` — struct; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `static none`, `static unconstrained`

### `ManipulationComponent.Dynamics.RotationBehavior` — struct; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `static none`, `static unconstrained`

### `ManipulationComponent.Dynamics.ScalingBehavior` — struct; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `static none`, `static unconstrained`

### `ManipulationComponent.Dynamics.Inertia` — struct; conforms to Hashable, Sendable
  - not iOS, visionOS 26.0: `static zero`, `static low`, `static medium`, `static high`

### `Component` — protocol (iOS 13.0)
  - iOS 13.0: `static registerComponent()`

### `TransientComponent` — protocol (iOS 15.0); conforms to Component

### `UnlitMaterial` — struct (iOS 13.0); conforms to Material
  - iOS 15.0: `color`, `opacityThreshold`, `blending`
  - iOS 13.0: `init()`
  - iOS 18.0, visionOS 1.0: `triangleFillMode`, `init(applyPostProcessToneMap:)`
  - iOS 18.0, visionOS 2.0: `writesDepth`, `readsDepth`, `program`, `init(program:)`, `init(texture:)`, `faceCulling`, `textureCoordinateTransform`, `secondaryTextureCoordinateTransform`

### `LightmapResource` — class; conforms to Resource, Sendable
  - unannotated: `init(atlasTextures:perEntityData:)`, `init(perEntityData:)`, `entityCount`, `bakeTypes`

### `LightmapResource.AtlasReference` — struct; conforms to Sendable
  - unannotated: `atlasTextureIndex`, `atlasTextureSlice`, `uvOffset`, `uvScale`, `init()`

### `LightmapResource.BakeType` — enum; conforms to Sendable
  - unannotated: `.ambientOcclusion`, `.indirectDiffuseIrradiance`, `.finalShadedColor`
  - iOS 27.0, visionOS 27.0: conforms to Equatable, conforms to Hashable

### `LightmapResource.BakeDescriptor` — enum; conforms to Sendable
  - unannotated: `.ambientOcclusion(...)`, `.indirectDiffuseIrradiance(...)`, `.finalShadedColor(...)`, `bakeType`

### `LightmapResource.AmbientOcclusionBakeDescriptor` — struct; conforms to Sendable
  - unannotated: `init(sourceAtlasReference:)`

### `LightmapResource.IndirectDiffuseIrradianceBakeDescriptor` — struct; conforms to Sendable
  - unannotated: `init(sourceAtlasReference:)`

### `LightmapResource.FinalShadedColorBakeDescriptor` — struct; conforms to Sendable
  - unannotated: `init(sourceAtlasReference:)`

### `LightmapResource.MeshPartLightmapDescriptor` — struct; conforms to Sendable
  - unannotated: `init(bakeDescriptor:)`

### `LightmapResource.EntityLightmapDescriptor` — struct; conforms to Sendable
  - unannotated: `init(perPartData:)`

### `BlendShapeWeightsMapping` — class (iOS 18.0, visionOS 2.0); conforms to Resource
  - iOS 18.0, visionOS 2.0: `init(meshResource:)`, `init(blendShapeName:weightNames:)`
- extension of `AffineTransform3D`
  - iOS 18.0, visionOS 1.0: `init(_:)`

### `ReverbMeshResource` — class; conforms to Resource
  - iOS 27.0, visionOS 27.0: `init(positions:triangleIndices:materials:)`, `static plane(width:depth:)`, `static box(size:)`, `static shoebox(size:)`, conforms to Hashable

### `MeshJointInfluence` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `init()`, `init(jointIndex:weight:)`, `jointIndex`, `weight`

### `MeshBuffers` — enum (iOS 15.0)
  - iOS 15.0: `static positions`, `static normals`, `static tangents`, `static bitangents`, `static textureCoordinates`, `static triangleIndices`, `static custom(_:type:)`
  - iOS 27.0, visionOS 27.0: `static textureCoordinates1`, `static textureCoordinates2`, `static textureCoordinates3`, `static textureCoordinates4`, `static textureCoordinates5`, `static textureCoordinates6`, `static textureCoordinates7`, `static uv2`, `static uv3`, `static uv4`, `static uv5`, `static uv6`, `static uv7`, `static textureCoordinates(_:)`
  - iOS 18.0, visionOS 1.0: `static jointInfluences`
  - iOS 18.0, visionOS 2.0: `static blendShapeOffsets(named:)`

### `MeshBuffers.Identifier` — struct; conforms to Hashable, Equatable, CustomStringConvertible, Sendable
  - iOS 15.0: `name`, `isCustom`, `static positions`, `static normals`, `static tangents`, `static bitangents`, `static textureCoordinates`, `static triangleIndices`, `description`
  - iOS 18.0, visionOS 2.0: `isBlendShape`
  - iOS 27.0, visionOS 27.0: `static textureCoordinates1`, `static textureCoordinates2`, `static textureCoordinates3`, `static textureCoordinates4`, `static textureCoordinates5`, `static textureCoordinates6`, `static textureCoordinates7`, `static uv2`, `static uv3`, `static uv4`, `static uv5`, `static uv6`, `static uv7`
  - iOS 18.0, visionOS 1.0: `static jointInfluences`

### `MeshBuffers.Rate` — enum
  - iOS 15.0: `.vertex`, `.face`, `.faceVarying`, conforms to Equatable, conforms to Hashable

### `MeshBuffers.ElementType` — enum
  - iOS 15.0: `.uInt8`, `.uInt16`, `.uInt32`, `.int8`, `.int16`, `.int32`, `.float`, `.double`, `.simd2Float`, `.simd3Float`, `.simd4Float`, conforms to Equatable, conforms to Hashable
  - iOS 18.0, visionOS 1.0: `.jointInfluence`

### `MeshBufferSemantic` — protocol (iOS 15.0); conforms to Identifiable
  - iOS 15.0: `assoc Element`, `id`

### `MeshBuffers.Semantic` — struct; conforms to MeshBufferSemantic
  - iOS 15.0: `id`

### `MeshBuffer` — struct (iOS 15.0); conforms to Sequence
  - iOS 15.0: `count`, `rate`, `elements`, `usingRate(_:)`, `forEach(_:)`, `init(_:)`, `init(elements:indices:)`
  - iOS 18.0, visionOS 1.0: `init(_:)`, `init(elements:indices:)`

### `MeshBuffer.Iterator` — struct; conforms to IteratorProtocol
  - iOS 15.0: `next()`

### `AnyMeshBuffer` — struct (iOS 15.0)
  - iOS 15.0: `id`, `count`, `rate`, `elementType`, `get(_:)`

### `MeshBufferContainer` — protocol (iOS 15.0)
  - iOS 15.0: `buffers`, `subscript(semantic:)`, `positions`, `normals`, `tangents`, `bitangents`, `textureCoordinates`
  - iOS 27.0, visionOS 27.0: `textureCoordinates1`, `textureCoordinates2`, `textureCoordinates3`, `textureCoordinates4`, `textureCoordinates5`, `textureCoordinates6`, `textureCoordinates7`, `uv2`, `uv3`, `uv4`, `uv5`, `uv6`, `uv7`
  - iOS 18.0, visionOS 2.0: `blendShapeOffsets(named:)`, `setBlendShapeOffsets(named:buffer:)`, `blendShapeNames`

### `MeshDescriptor` — struct (iOS 15.0); conforms to MeshBufferContainer
  - iOS 15.0: `init(name:)`, `name`, `materials`, `primitives`, `buffers`, `subscript(semantic:)`

### `MeshDescriptor.Materials` — enum
  - iOS 15.0: `.allFaces(...)`, `.perFace(...)`

### `MeshDescriptor.Primitives` — enum
  - iOS 15.0: `.triangles(...)`, `.polygons(...)`, `.trianglesAndQuads(...)`

### `Audio.Absorption` — struct; conforms to Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `init(_:)`, `static default`, `static uniform(_:)`, `scaled(by:)`, conforms to ExpressibleByDictionaryLiteral, `init(dictionaryLiteral:)`

### `CustomMaterial.ResourceStorage` — struct; conforms to ~Copyable
  - iOS 18.0, not visionOS: `subscript(textureResource:)`
  - iOS 26.0, not visionOS: `subscript(buffer:)`

### `CustomShaderStage` — enum (iOS 18.0, not visionOS); conforms to Equatable, Hashable, Sendable
  - iOS 18.0, not visionOS: `.geometryModifier`, `.surfaceShader`

### `TextComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `size`, `text`, `backgroundColor`, `cornerRadius`, `init()`

### `AudioGeneratorController` — class
  - unannotated: `entity`, `configuration`
  - iOS 18.0, visionOS 2.0: `gain`, `isPlaying`, `play()`, `stop()`, conforms to Sendable

### `Event` — protocol (iOS 13.0); conforms to Sendable

### `EventSource` — protocol (iOS 13.0)

### `PhysicsSimulationEvents` — enum (iOS 18.0, visionOS 1.0)

### `PhysicsSimulationEvents.WillSimulate` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `deltaTime`
  - deprecated: `simulationEntity`
  - iOS 26.0, visionOS 26.0: `simulationRootEntity`

### `PhysicsSimulationEvents.DidSimulate` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `deltaTime`
  - deprecated: `simulationEntity`
  - iOS 26.0, visionOS 26.0: `simulationRootEntity`

### `SceneEvents` — enum (iOS 13.0)

### `SceneEvents.Update` — struct; conforms to Event
  - iOS 13.0: `scene`, `deltaTime`

### `SceneEvents.AnchoredStateChanged` — struct; conforms to Event
  - iOS 13.0: `isAnchored`, `anchor`

### `SceneEvents.DidAddEntity` — struct; conforms to Event
  - iOS 15.0: `entity`

### `SceneEvents.DidActivateEntity` — struct; conforms to Event
  - iOS 15.0: `entity`

### `SceneEvents.WillDeactivateEntity` — struct; conforms to Event
  - iOS 15.0: `entity`

### `SceneEvents.WillRemoveEntity` — struct; conforms to Event
  - iOS 15.0: `entity`

### `SceneEvents.DidReparentEntity` — struct; conforms to Event
  - iOS 15.0: `child`, `previousParent`

### `AnimationEvents` — enum (iOS 13.0)

### `AnimationEvents.PlaybackCompleted` — struct; conforms to Event
  - iOS 13.0: `playbackController`

### `AnimationEvents.PlaybackLooped` — struct; conforms to Event
  - iOS 13.0: `playbackController`

### `AnimationEvents.PlaybackTerminated` — struct; conforms to Event
  - iOS 13.0: `playbackController`

### `AnimationEvents.PlaybackStarted` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `playbackController`

### `AnimationEvents.SkeletalPoseUpdateComplete` — struct; conforms to Event
  - iOS 18.0, visionOS 2.0: `deltaTime`

### `AnimationEvents.RootMotionDidUpdate` — struct; conforms to Event
  - iOS 27.0, visionOS 27.0: `entity`, `rootMotionTransform`, `deltaTime`, `suppressesAutomaticApplication`

### `AudioEvents` — enum (iOS 13.0)

### `AudioEvents.PlaybackCompleted` — struct; conforms to Event
  - iOS 13.0: `playbackController`

### `AudioEvents.PlaybackGroupCompleted` — struct; conforms to Event
  - iOS 27.0, visionOS 27.0: `playbackController`

### `Contact` — struct (iOS 18.0, visionOS 1.0); conforms to Sendable
  - iOS 18.0, visionOS 1.0: `point`, `normal`, `impulse`, `impulseDirection`, `penetrationDistance`

### `CollisionEvents` — enum (iOS 13.0)

### `CollisionEvents.Began` — struct; conforms to Event
  - iOS 13.0: `entityA`, `entityB`, `position`, `impulse`
  - iOS 18.0, visionOS 1.0: `penetrationDistance`, `impulseDirection`, `contacts`

### `CollisionEvents.Updated` — struct; conforms to Event
  - iOS 13.0: `entityA`, `entityB`, `position`, `impulse`
  - iOS 18.0, visionOS 1.0: `penetrationDistance`, `impulseDirection`, `contacts`

### `CollisionEvents.Ended` — struct; conforms to Event
  - iOS 13.0: `entityA`, `entityB`

### `SynchronizationEvents` — enum (iOS 13.0)

### `SynchronizationEvents.OwnershipRequest` — struct; conforms to Event
  - iOS 13.0: `entity`, `requester`, `accept`

### `SynchronizationEvents.OwnershipChanged` — struct; conforms to Event
  - iOS 13.0: `entity`, `newOwner`

### `ComponentEvents` — enum (iOS 15.0)

### `ComponentEvents.DidAdd` — struct; conforms to Event
  - iOS 15.0: `entity`, `componentType`

### `ComponentEvents.DidActivate` — struct; conforms to Event
  - iOS 15.0: `entity`, `componentType`

### `ComponentEvents.WillDeactivate` — struct; conforms to Event
  - iOS 15.0: `entity`, `componentType`

### `ComponentEvents.WillRemove` — struct; conforms to Event
  - iOS 15.0: `entity`, `componentType`

### `ComponentEvents.DidChange` — struct; conforms to Event
  - iOS 15.0: `entity`, `componentType`

### `ManipulationEvents` — enum (not iOS, visionOS 26.0)

### `ManipulationEvents.WillBegin` — struct; conforms to Event
  - not iOS, visionOS 26.0: `entity`, `inputDeviceSet`, `pivotPoint`

### `ManipulationEvents.DidUpdateTransform` — struct; conforms to Event
  - not iOS, visionOS 26.0: `entity`, `inputDeviceSet`, `pivotPoint`

### `ManipulationEvents.WillRelease` — struct; conforms to Event
  - not iOS, visionOS 26.0: `entity`, `inputDeviceSet`, `wasCancelled`

### `ManipulationEvents.WillEnd` — struct; conforms to Event
  - not iOS, visionOS 26.0: `entity`

### `ManipulationEvents.DidHandOff` — struct; conforms to Event
  - not iOS, visionOS 26.0: `entity`, `oldInputDeviceSet`, `newInputDeviceSet`

### `VideoPlayerEvents` — enum (iOS 18.0, visionOS 1.0)

### `VideoPlayerEvents.ContentTypeDidChange` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `contentType`, `previousType`

### `VideoPlayerEvents.ContentTypeDidChange.ContentType` — enum; conforms to UInt8, Sendable
  - iOS 18.0, visionOS 1.0: `.invalid`, `.mono`, `init(rawValue:)`, `rawValue`, conforms to Equatable, conforms to Hashable, conforms to RawRepresentable
  - not iOS, visionOS 1.0: `.stereo`, `.immersive`
  - not iOS, visionOS 26.0: `.halfEquirectangular`, `.equirectangular`, `.parametricImmersive`

### `VideoPlayerEvents.ViewingModeDidChange` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `currentViewingMode`, `previousViewingMode`

### `VideoPlayerEvents.ImmersiveViewingModeDidChange` — struct (not iOS, visionOS 2.0); conforms to Event
  - not iOS, visionOS 2.0: `previousMode`, `currentMode`

### `VideoPlayerEvents.ImmersiveViewingModeWillTransition` — struct (not iOS, visionOS 2.0); conforms to Event
  - not iOS, visionOS 2.0: `previousMode`, `currentMode`

### `VideoPlayerEvents.ImmersiveViewingModeDidTransition` — struct (not iOS, visionOS 2.0); conforms to Event
  - not iOS, visionOS 2.0: `previousMode`, `currentMode`

### `VideoPlayerEvents.VideoSizeDidChange` — struct; conforms to Event
  - iOS 18.0, visionOS 1.0: `screenMeshSize`, `videoDimension`

### `VideoPlayerEvents.RenderingStatusDidChange` — struct (iOS 18.0, visionOS 26.0); conforms to Event, Sendable
  - iOS 18.0, visionOS 26.0: `previousStatus`, `currentStatus`

### `VideoPlayerEvents.VideoComfortMitigationDidOccur` — struct; conforms to Event
  - not iOS, visionOS 26.0: `comfortMitigation`

### `ImagePresentationEvents` — enum (not iOS, visionOS 26.0)

### `ImagePresentationEvents.TransitionStarted` — struct; conforms to Event
  - not iOS, visionOS 26.0: `currentViewingMode`, `targetViewingMode`

### `ImagePresentationEvents.TransitionCompleted` — struct; conforms to Event
  - not iOS, visionOS 26.0: `previousViewingMode`, `currentViewingMode`

### `Scene.Publisher` — struct; conforms to Publisher where E : Event
  - iOS 13.0: `receive(subscriber:)`

### `AnchorStateEvents` — enum (iOS 26.0, visionOS 26.0)

### `AnchorStateEvents.DidAnchor` — struct (iOS 26.0, visionOS 26.0); conforms to Event
  - iOS 26.0, visionOS 26.0: `entity`, `reason`

### `AnchorStateEvents.DidAnchor.Reason` — enum (iOS 26.0, visionOS 26.0); conforms to Sendable, Equatable
  - iOS 26.0, visionOS 26.0: `.newAnchor`, `.reanchor`, conforms to Hashable

### `AnchorStateEvents.WillUnanchor` — struct (iOS 26.0, visionOS 26.0); conforms to Event
  - iOS 26.0, visionOS 26.0: `entity`, `reason`

### `AnchorStateEvents.WillUnanchor.Reason` — enum (iOS 26.0, visionOS 26.0); conforms to Sendable, Hashable
  - iOS 26.0, visionOS 26.0: `.anchorDisqualified`, `.authorizationFailed`

### `AnchorStateEvents.DidFailToAnchor` — struct (iOS 26.0, visionOS 26.0); conforms to Event
  - iOS 26.0, visionOS 26.0: `entity`, `reason`

### `AnchorStateEvents.DidFailToAnchor.Reason` — enum (iOS 26.0, visionOS 26.0); conforms to Sendable, Hashable
  - iOS 26.0, visionOS 26.0: `.addAnchorFailed`, `.maximumLimitReached`, `.anchorNotSupported`, `.unspecified`

### `SceneEvents.TrackingStateUpdate` — struct (not iOS, visionOS 26.0); conforms to Event
  - not iOS, visionOS 26.0: `previous`, `current`

### `SceneEvents.TrackingStateUpdate.State` — enum (not iOS, visionOS 26.0); conforms to Sendable, Hashable
  - not iOS, visionOS 26.0: `.tracked`, `.untracked`, `.orientationTracked`

### `ModelComponent` — struct (iOS 13.0); conforms to Component
  - iOS 13.0: `mesh`, `materials`, `init(mesh:materials:)`
  - iOS 15.0: `boundsMargin`

### `MeshModelCollection` — struct (iOS 15.0)
  - iOS 15.0: `count`, `isEmpty`, `init()`, `init(_:)`, `subscript(id:)`, `insert(_:)`, `update(_:)`, `remove(id:)`, `removeAll()`, conforms to Sequence, conforms to ExpressibleByArrayLiteral, `init(arrayLiteral:)`
  - iOS 18.0, visionOS 2.0: conforms to Collection, `startIndex`, `endIndex`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`

### `MeshModelCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 15.0: `next()`

### `MeshPartCollection` — struct (iOS 15.0)
  - iOS 15.0: `count`, `isEmpty`, `init()`, `init(_:)`, `subscript(id:)`, `insert(_:)`, `update(_:)`, `remove(id:)`, `removeAll()`, conforms to Sequence, conforms to ExpressibleByArrayLiteral, `init(arrayLiteral:)`
  - iOS 18.0, visionOS 2.0: conforms to Collection, `startIndex`, `endIndex`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`

### `MeshPartCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 15.0: `next()`

### `MeshInstanceCollection` — struct (iOS 15.0)
  - iOS 15.0: `count`, `isEmpty`, `init()`, `init(_:)`, `subscript(id:)`, `insert(_:)`, `update(_:)`, `remove(id:)`, `removeAll()`, conforms to Sequence, conforms to ExpressibleByArrayLiteral, `init(arrayLiteral:)`
  - iOS 18.0, visionOS 2.0: conforms to Collection, `startIndex`, `endIndex`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`

### `MeshInstanceCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 15.0: `next()`

### `MeshSkeletonCollection` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `count`, `isEmpty`, `init()`, `init(_:)`, `subscript(id:)`, `insert(_:)`, `update(_:)`, `remove(id:)`, `removeAll()`, conforms to Sequence, conforms to ExpressibleByArrayLiteral, `init(arrayLiteral:)`
  - iOS 18.0, visionOS 2.0: conforms to Collection, `startIndex`, `endIndex`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`

### `MeshSkeletonCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 1.0: `next()`

### `MeshResource` — class; conforms to Resource
  - iOS 15.0: `contents`, `replace(with:)`, `static generate(from:)`
  - deprecated: `replaceAsync(with:)`, `static generateAsync(from:)`
  - iOS 18.0, visionOS 1.0: `replace(with:)`, `static generateBox(size:majorCornerRadius:minorCornerRadius:)`, `static generateCone(height:radius:)`, `static generateCylinder(height:radius:)`, `init(shape:)`
  - iOS 18.0, visionOS 2.0: `lowLevelMesh`, `init(extruding:textOptions:extrusionOptions:)`
  - iOS 26.0, visionOS 26.0: `meshPartIndex(modelID:partID:)`, `getMeshPartIndex(modelID:partID:)`
  - unannotated: `expectedMaterialCount`, `bounds`, `static generateBox(size:cornerRadius:)`, `static generateBox(width:height:depth:cornerRadius:splitFaces:)`, `static generatePlane(width:height:cornerRadius:)`, `static generatePlane(width:depth:cornerRadius:)`, `static generateSphere(radius:)`

### `MeshResource.Part` — struct; conforms to MeshBufferContainer, Identifiable
  - iOS 15.0: `id`, `materialIndex`, `init(id:materialIndex:)`, `triangleIndices`, `buffers`, `subscript(semantic:)`
  - iOS 18.0, visionOS 1.0: `skeletonID`, `jointInfluences`

### `MeshResource.Model` — struct; conforms to Identifiable
  - iOS 15.0: `id`, `parts`, `init(id:parts:)`, `init(id:descriptors:)`

### `MeshResource.Instance` — struct; conforms to Identifiable
  - iOS 15.0: `id`, `model`, `transform`, `init(id:model:at:)`

### `MeshResource.Contents` — struct
  - iOS 15.0: `models`, `instances`, `init()`
  - iOS 18.0, visionOS 1.0: `skeletons`

### `MeshResource.Skeleton` — struct; conforms to Identifiable
  - iOS 18.0, visionOS 1.0: `id`, `joints`, `init(id:joints:)`, `init(id:jointNames:inverseBindPoseMatrices:restPoseTransforms:parentIndices:)`

### `MeshResource.Skeleton.Joint` — struct; conforms to Equatable
  - iOS 18.0, visionOS 1.0: `name`, `parentIndex`, `inverseBindPoseMatrix`, `restPoseTransform`, `init(name:parentIndex:inverseBindPoseMatrix:restPoseTransform:)`

### `MeshResource.JointInfluences` — struct
  - iOS 18.0, visionOS 1.0: `influences`, `init(influences:influencesPerVertex:)`

### `MaterialParameterTypes` — struct (iOS 15.0)

### `MaterialParameterTypes.FaceCulling` — enum (iOS 15.0)
  - iOS 15.0: `.none`, `.front`, `.back`, conforms to Equatable, conforms to Hashable

### `MaterialParameterTypes.TextureCoordinateTransform` — struct (iOS 15.0)
  - iOS 15.0: `offset`, `scale`, `rotation`, `init(offset:scale:rotation:)`

### `MaterialParameterTypes.TriangleFillMode` — enum (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `.fill`, `.lines`, conforms to Equatable, conforms to Hashable

### `MaterialParameterTypes.BlendMode` — enum; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `.alpha`, `.add`

### `Entity.ChildCollection` — struct; conforms to Collection
  - iOS 13.0: `startIndex`, `endIndex`, `index(after:)`, `subscript(index:)`, `append(_:preservingWorldTransform:)`, `append(contentsOf:preservingWorldTransforms:)`, `remove(_:preservingWorldTransform:)`, `remove(at:preservingWorldTransform:)`, `removeAll(keepCapacity:preservingWorldTransforms:)`, `removeAll(preservingWorldTransforms:)`, `replaceAll(_:preservingWorldTransforms:)`, conforms to CustomStringConvertible, `description`, conforms to Sendable
  - iOS 18.0, visionOS 1.0: conforms to EntityCollection, `append(contentsOf:)`, `remove(_:)`, `insert(contentsOf:beforeIndex:)`, `remove(at:)`, `removeAll()`, `replaceAll(_:)`

### `Entity.ChildCollection.IndexingIterator` — struct; conforms to Collection
  - iOS 13.0: `init(_elements:)`, `init(_elements:_position:)`, conforms to IteratorProtocol, Sequence, `next()`

### `EntityCollection` — protocol (iOS 18.0, visionOS 1.0); conforms to Collection where Self.Element == Entity, Self.Index == Int
  - iOS 18.0, visionOS 1.0: `append(_:)`, `append(contentsOf:)`, `insert(_:beforeIndex:)`, `insert(contentsOf:beforeIndex:)`, `remove(_:)`, `remove(at:)`, `removeAll()`, `removeAll(where:)`, `replaceAll(_:)`

### `HasDirectionalLight` — protocol (iOS 13.0, visionOS 2.0); conforms to HasTransform
  - iOS 13.0, visionOS 2.0: `light`, `shadow`

### `IKComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `resource`, `solvers`, `init(resource:)`

### `IKComponent.Solver` — class; conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `maxIterations`, `globalFkWeight`, `reset()`, `joints`, `constraints`

### `IKComponent.Solver.ID` — struct; conforms to Hashable, Equatable

### `IKComponent.Joint` — class; conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `name`, `fkWeightPerAxis`, `rotationStiffness`

### `IKComponent.Constraint` — class; conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `name`, `jointID`, `demands`, `target`, `offset`, `lookAtTargetPosition`, `animationOverrideWeight`

### `IKComponent.Constraint.DemandOptions` — struct; conforms to OptionSet
  - iOS 18.0, visionOS 2.0: `rawValue`, `init(rawValue:)`

### `IKComponent.SolverCollection` — struct; conforms to Collection, Sequence
  - iOS 18.0, visionOS 2.0: `subscript(id:)`, `count`, `isEmpty`, `contains(_:)`, `set(_:)`, `startIndex`, `endIndex`, `subscript(position:)`, `index(after:)`

### `IKComponent.SolverCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `IKComponent.JointCollection` — struct; conforms to Collection, Sequence
  - iOS 18.0, visionOS 2.0: `subscript(id:)`, `subscript(name:)`, `count`, `isEmpty`, `contains(_:)`, `set(_:)`, `startIndex`, `endIndex`, `subscript(position:)`, `index(after:)`

### `IKComponent.JointCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `IKComponent.ConstraintCollection` — struct; conforms to Collection, Sequence
  - iOS 18.0, visionOS 2.0: `subscript(id:)`, `subscript(name:)`, `count`, `isEmpty`, `contains(_:)`, `set(_:)`, `startIndex`, `endIndex`, `subscript(position:)`, `index(after:)`

### `IKComponent.ConstraintCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `SkeletonResource` — class; conforms to Resource, @unchecked Sendable
  - unannotated: `name`, `animationEvaluation`, `rootJoint`, `init(named:rootJoint:animationEvaluation:)`

### `SkeletonResource.JointBuilder` — struct
  - unannotated: `static buildExpression(_:)`, `static buildBlock(_:)`

### `SkeletonResource.Joint` — struct; conforms to Identifiable, Sendable
  - unannotated: `name`, `restPoseTransform`, `children`, `id`

### `SkeletonResource.BlendMask` — struct; conforms to Identifiable, Sendable
  - unannotated: `name`, `jointWeights`, `id`, `init(name:jointWeights:)`

### `SkeletonResource.AnimationEvaluation` — struct; conforms to Sendable
  - unannotated: `ikResources`, `blendMasks`, `init(ikResources:blendMasks:)`

### `Scene.AnchorCollection` — struct; conforms to Collection
  - iOS 13.0: `startIndex`, `endIndex`, `index(after:)`, `subscript(index:)`, `append(_:)`, `append(contentsOf:)`, `remove(_:)`, `remove(at:)`, `removeAll(keepCapacity:)`, `removeAll()`, `replaceAll(_:)`, conforms to CustomStringConvertible, `description`, conforms to Sendable

### `GroundingShadowComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `castsShadow`, `init(castsShadow:)`
  - iOS 18.0, visionOS 2.0: `receivesShadow`, `init(castsShadow:receivesShadow:)`, `fadeBehaviorNearPhysicalObjects`, `init(castsShadow:receivesShadow:fadeBehaviorNearPhysicalObjects:)`

### `GroundingShadowComponent.FadeBehaviorNearPhysicalObjects` — enum
  - iOS 18.0, visionOS 2.0: `.default`, `.fade`, `.constant`, conforms to Equatable, conforms to Hashable

### `EnvironmentResource` — class; conforms to Resource
  - unannotated: `static load(named:in:)`
  - deprecated: `static loadAsync(named:in:)`
  - not iOS: `static generate(fromEquirectangular:withName:)`
  - iOS 18.0, visionOS 1.0: `init(named:in:)`, `skybox`
  - iOS 18.0, visionOS 2.0: `init(cube:options:)`, `init(equirectangular:withName:)`
  - iOS 27.0, visionOS 27.0: `init(named:in:skyboxMode:)`, `init(equirectangular:options:)`, `init(skybox:specular:diffuse:)`

### `EnvironmentResource.CreateOptions` — struct; conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `compression`, `samplingQuality`, `specularCubeDimension`, `init(samplingQuality:specularCubeDimension:compression:)`
  - iOS 27.0, visionOS 27.0: `skyboxMode`, `init(skyboxMode:samplingQuality:specularCubeDimension:compression:)`

### `EnvironmentResource.CreateOptions.SamplingQuality` — enum; conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `.fast`, `.normal`

### `EnvironmentResource.SkyboxMode` — struct (iOS 27.0, visionOS 27.0); conforms to Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `static preserve`, `static discard`

### `Reverb` — struct (iOS 18.0, visionOS 2.0); conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `static anechoic`, `static preset(_:)`
  - iOS 27.0, visionOS 27.0: `static simulated(mesh:materials:)`

### `Reverb.Preset` — struct; conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `static outside`, `static concertHall`, `static veryLargeRoom`, `static largeRoom`, `static largeRoomTreated`, `static mediumRoomDry`, `static mediumRoomTreated`, `static smallRoomBright`, `static smallRoom`, `static verySmallRoomBright`
- extension of `Rect3D`
  - iOS 18.0, visionOS 1.0: `init(_:)`

### `BoundingBox` — struct (iOS 13.0); conforms to Hashable, Sendable
  - iOS 18.0, visionOS 1.0: `init(_:)`
  - iOS 13.0: `static empty`, `min`, `max`, `init()`, `init(min:max:)`, `center`, `extents`, `boundingRadius`, `isEmpty`, `union(_:)`, `formUnion(_:)`, `contains(_:)`, `intersects(_:)`, `transformed(by:)`, `transform(by:)`, `distanceSquared(toPoint:)`, conforms to BitwiseCopyable
  - iOS 26.0, visionOS 26.0: conforms to Codable

### `SetEntityEnabledAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `targetEntity`, `isEnabled`, `animatedValueType`, `init(targetEntity:isEnabled:)`

### `InputTargetComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 1.0: `isEnabled`, `allowedInputTypes`, `init(allowedInputTypes:)`

### `InputTargetComponent.InputType` — struct; conforms to OptionSet
  - iOS 18.0, visionOS 1.0: `static direct`, `static indirect`, `static all`, `init(rawValue:)`, `rawValue`

### `ParticleEmitterComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Codable
  - iOS 18.0, visionOS 1.0: `init()`, `emitterShape`, `birthLocation`, `birthDirection`, `emitterShapeSize`, `speed`, `speedVariation`, `emissionDirection`, `radialAmount`, `torusInnerRadius`, `spawnOccasion`, `spawnVelocityFactor`, `spawnSpreadFactor`, `spawnSpreadFactorVariation`, `spawnInheritsParentColor`, `simulationState`, `particlesInheritTransform`, `fieldSimulationSpace`, `restart()`, `isEmitting`, `burst()`, `burstCount`, `burstCountVariation`, `mainEmitter`, `spawnedEmitter`

### `BillboardComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `init()`, `blendFactor`

### `PhysicallyBasedDecalComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init(baseColor:)`, `init()`, `baseColor`, `normal`, `roughness`, `metallic`, `specular`, `emissive`, `opacity`, `receiverEntities`, `sortOrder`, `layers`, `bounds`

### `Entity.Observable.Components` — struct (iOS 26.0, visionOS 26.0)
  - iOS 26.0, visionOS 26.0: `subscript(componentType:)`, `subscript(type:)`
  - unannotated: conforms to Sendable

### `AmbientAudioComponent` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `gain`, `init(gain:)`, conforms to Component, conforms to Equatable, Hashable, Codable

### `ChannelAudioComponent` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `gain`, `init(gain:)`, conforms to Component, conforms to Equatable, Hashable, Codable

### `AudioGeneratorConfiguration` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `layoutTag`, `mixGroupName`, `init(layoutTag:mixGroupName:)`

### `ModelSortGroup` — struct (iOS 18.0, visionOS 1.0); conforms to Equatable, Sendable
  - iOS 18.0, visionOS 1.0: `init(depthPass:)`, `depthPass`
  - iOS 18.0, visionOS 2.0: `planarUIPlacement`, `static planarUIInline`, `static planarUIAlwaysInFront`, `static planarUIAlwaysBehind`

### `ModelSortGroup.DepthPass` — enum; conforms to Sendable
  - iOS 18.0, visionOS 1.0: `.prePass`, `.postPass`, conforms to Equatable, conforms to Hashable

### `ModelSortGroup.PlanarUIPlacement` — enum (iOS 18.0, visionOS 2.0); conforms to Sendable
  - iOS 18.0, visionOS 2.0: `.inlineUI`, `.alwaysInFront`, `.alwaysBehind`, conforms to Equatable, conforms to Hashable

### `ModelSortGroupComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `init(group:order:)`, `group`, `order`

### `GeometricPin` — struct (iOS 18.0, visionOS 2.0); conforms to Hashable
  - iOS 18.0, visionOS 2.0: `init(named:offsetPosition:offsetOrientation:)`, `init(named:skeletalJointName:offsetPosition:offsetOrientation:)`, `position`, `orientation`, `position(relativeTo:)`, `orientation(relativeTo:)`, `entity`, `name`, `offsetPosition`, `offsetOrientation`

### `CharacterControllerStateComponent` — struct (iOS 15.0); conforms to Component
  - iOS 15.0: `init()`, `velocity`, `isOnGround`

### `Audio.Directivity` — enum
  - iOS 18.0, visionOS 1.0: `.beam(...)`, conforms to Equatable, Hashable, Codable

### `Entity.CoordinateSpaceReference` — enum (not iOS, visionOS 2.0)
  - not iOS, visionOS 2.0: `.scene`, `.immersiveSpace`, conforms to Equatable, conforms to Hashable

### `PhysicsMotionComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `linearVelocity`, `angularVelocity`, `init()`, `init(linearVelocity:angularVelocity:)`

### `AnimationLibraryComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, ExpressibleByDictionaryLiteral
  - iOS 18.0, visionOS 2.0: `init(dictionaryLiteral:)`, `init(animations:)`, `init()`, `defaultAnimation`, `defaultKey`, `removeAll(resource:)`, `unkeyedResources`, `animations`
  - iOS 27.0, visionOS 27.0: `init(animations:automaticallyPlaysDefaultAnimation:)`, `init(automaticallyPlaysDefaultAnimation:)`, `automaticallyPlaysDefaultAnimation`

### `AnimationLibraryComponent.AnimationCollection` — struct; conforms to Collection
  - iOS 18.0, visionOS 2.0: `init(dictionaryLiteral:)`, `count`, `isEmpty`, `startIndex`, `endIndex`, `subscript(key:)`, `subscript(bounds:)`, `index(after:)`, `formIndex(after:)`, `subscript(position:)`

### `AnimationLibraryComponent.AnimationCollection.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `AnimationLibraryComponent.AnimationCollection.Index` — struct; conforms to Comparable, Hashable, Sendable

### `PhotogrammetrySession.Output` — enum
  - iOS 17.0, not visionOS: conforms to Sendable
  - not visionOS: `.inputComplete`, `.requestError(...)`, `.requestComplete(...)`, `.requestProgress(...)`, `.processingComplete`, `.processingCancelled`, `.invalidSample(...)`, `.skippedSample(...)`, `.automaticDownsampling`, `localizedDescription`
  - iOS 17.0: `.requestProgressInfo(...)`, `.stitchingIncomplete`

### `PhotogrammetrySession.Result` — enum
  - iOS 17.0, not visionOS: conforms to Sendable
  - not visionOS: `.modelFile(...)`, `.modelEntity(...)`, `.bounds(...)`
  - iOS 17.0: `.pointCloud(...)`, `.poses(...)`

### `PhotogrammetrySession.Output.ProcessingStage` — enum (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable, conforms to Equatable, conforms to Hashable
  - iOS 17.0: `.preProcessing`, `.imageAlignment`, `.pointCloudGeneration`, `.meshGeneration`, `.textureMapping`, `.optimization`

### `PhotogrammetrySession.Output.ProgressInfo` — struct (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `estimatedRemainingTime`, `processingStage`

### `PhotogrammetrySession.Request` — enum; conforms to Hashable
  - iOS 17.0, not visionOS: conforms to Sendable
  - not visionOS: `.modelFile(...)`, `.modelEntity(...)`, `.bounds`, `init(modelFile:)`
  - iOS 17.0: `.pointCloud`, `.poses`

### `PhotogrammetrySession.Request.Geometry` — struct; conforms to Hashable
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `orientedBounds`, `init(orientedBounds:transform:)`
  - not visionOS: `bounds`, `transform`, `init(bounds:transform:)`

### `PhotogrammetrySession.Request.Detail` — enum; conforms to Int, Hashable
  - iOS 17.0, not visionOS: conforms to Sendable, conforms to RawRepresentable
  - not visionOS: `.reduced`, `init(rawValue:)`, `rawValue`

### `PhotogrammetrySession.Limits` — struct (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `maximumInputImageDimension`, `maximumNumberOfInputImages`

### `PhotogrammetrySession.Configuration` — struct; conforms to Equatable
  - iOS 17.0, not visionOS: conforms to Sendable
  - not visionOS: `isObjectMaskingEnabled`, `sampleOrdering`, `featureSensitivity`, `init()`
  - iOS 17.0: `checkpointDirectory`, `init(checkpointDirectory:)`
  - iOS 18.0, not visionOS: `ignoreBoundingBox`

### `PhotogrammetrySession.Configuration.SampleOrdering` — enum
  - iOS 17.0, not visionOS: conforms to Sendable, conforms to Equatable, conforms to Hashable
  - not visionOS: `.unordered`, `.sequential`

### `PhotogrammetrySession.Configuration.FeatureSensitivity` — enum
  - iOS 17.0, not visionOS: conforms to Sendable, conforms to Equatable, conforms to Hashable
  - not visionOS: `.normal`, `.high`

### `PhotogrammetrySession.Error` — enum (iOS 17.0); conforms to Error, LocalizedError
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `.invalidImages(...)`, `.invalidOutput(...)`, `.insufficientStorage(...)`, `localizedDescription`

### `PhotogrammetrySession.PointCloud` — struct (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `points`

### `PhotogrammetrySession.PointCloud.Point` — struct
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `position`, `color`

### `PhotogrammetrySession.Pose` — struct (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `translation`, `rotation`, `transform`
  - iOS 26.0, not visionOS: `intrinsics`, `lensDistortionData`

### `PhotogrammetrySession.Poses` — struct (iOS 17.0)
  - iOS 17.0, not visionOS: conforms to Sendable
  - iOS 17.0: `posesBySample`, `urlsBySample`

### `Entity.Observable` — struct (iOS 26.0, visionOS 26.0)
  - iOS 26.0, visionOS 26.0: `name`, `isEnabled`, `children`, `transform`, `position`, `scale`, `orientation`, `components`
  - unannotated: conforms to Sendable

### `RenderLayer` — struct (iOS 27.0, visionOS 27.0); conforms to Sendable
  - iOS 27.0, visionOS 27.0: `static defaultLayer`, `init(_:)`, `init(rawValue:)`
  - unannotated: conforms to CustomStringConvertible, `description`, conforms to Hashable, conforms to Equatable

### `RenderLayer.Set` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `init()`, `init(_:)`, `isEmpty`, `count`, `contains(_:)`, `insert(_:)`, `remove(_:)`, conforms to Equatable, conforms to Sequence, `makeIterator()`
  - unannotated: conforms to ExpressibleByArrayLiteral, `init(arrayLiteral:)`

### `RenderLayer.Set.Iterator` — struct; conforms to IteratorProtocol
  - iOS 27.0, visionOS 27.0: `next()`

### `RenderLayerComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `layers`, `init(layers:)`, `init(_:)`, `init(layer:)`, `static defaultLayer`

### `QueryPredicate` — struct (iOS 15.0)
  - iOS 15.0: `static has(_:)`

### `LowLevelMesh` — class (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `descriptor`, `indexCapacity`, `vertexCapacity`, `parts`, `init(descriptor:)`, `read(bufferIndex:using:)`, `replace(bufferIndex:using:)`, `readIndices(using:)`, `replaceIndices(using:)`, `withUnsafeBytes(bufferIndex:_:)`, `withUnsafeMutableBytes(bufferIndex:_:)`, `replaceUnsafeMutableBytes(bufferIndex:_:)`, `withUnsafeIndices(_:)`, `withUnsafeMutableIndices(_:)`, `replaceUnsafeMutableIndices(_:)`, conforms to Sendable

### `LowLevelMesh.VertexSemantic` — enum; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `.position`, `.color`, `.normal`, `.tangent`, `.bitangent`, `.uv0`, `.uv1`, `.uv2`, `.uv3`, `.uv4`, `.uv5`, `.uv6`, `.uv7`, `.unspecified`, conforms to Equatable, conforms to Hashable

### `LowLevelMesh.Attribute` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(semantic:format:layoutIndex:offset:)`, `semantic`, `format`, `offset`, `layoutIndex`

### `LowLevelMesh.Layout` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(bufferIndex:bufferOffset:bufferStride:)`, `bufferIndex`, `bufferOffset`, `bufferStride`
  - iOS 27.0, visionOS 27.0: `init(bufferIndex:bufferOffset:bufferStride:stepFunction:stepRate:)`, `stepFunction`, `stepRate`

### `LowLevelMesh.Descriptor` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType:)`, `static maxVertexBufferCount`, `vertexBufferCount`, `vertexCapacity`, `vertexAttributes`, `vertexLayouts`, `indexCapacity`, `indexType`
  - iOS 27.0, visionOS 27.0: `init(vertexCapacity:vertexAttributes:vertexLayouts:indexCapacity:indexType:instanceCapacity:)`, `instanceCapacity`, `allowsPrimitiveRestart`

### `LowLevelMesh.Part` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(indexOffset:indexCount:topology:materialIndex:bounds:)`, `indexOffset`, `indexCount`, `topology`, `materialIndex`, `bounds`

### `LowLevelMesh.PartsCollection` — struct
  - iOS 18.0, visionOS 2.0: conforms to MutableCollection, RandomAccessCollection, `startIndex`, `endIndex`, `count`, `index(after:)`, `subscript(position:)`, `append(_:)`, `append(contentsOf:)`, `removeAll()`, `replaceAll(_:)`

### `VirtualEnvironmentProbeComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `source`, `init(source:)`
  - iOS 27.0, visionOS 27.0: `init(source:influence:)`, `influence`

### `VirtualEnvironmentProbeComponent.Source` — enum
  - iOS 18.0, visionOS 2.0: `.none`, `.single(...)`, `.blend(...)`

### `VirtualEnvironmentProbeComponent.Probe` — struct
  - iOS 18.0, visionOS 2.0: `environment`, `intensityExponent`, `init(environment:intensityExponent:)`

### `VirtualEnvironmentProbeComponent.Influence` — struct
  - iOS 27.0, visionOS 27.0: `static global`, `static local(parallaxBounds:blendDistance:)`, `static local(parallaxBounds:influenceBounds:blendDistance:)`

### `Entity.ConfigurationCatalog` — struct
  - iOS 18.0, visionOS 2.0: `init(configurationSets:combinations:)`, `write(to:)`, `configurationSets`
  - iOS 26.0, visionOS 26.0: conforms to Equatable

### `Entity.ConfigurationCatalog.Configuration` — struct; conforms to Identifiable, Sendable
  - iOS 18.0, visionOS 2.0: `id`, `init(id:)`

### `Entity.ConfigurationCatalog.ConfigurationSet` — struct; conforms to Identifiable, Sendable
  - iOS 18.0, visionOS 2.0: `id`, `configurations`, `defaultConfiguration`, `init(id:configurations:defaultConfigurationId:)`
  - iOS 26.0, visionOS 26.0: conforms to Equatable

### `Entity.ConfigurationCatalog.ConfigurationCombination` — struct
  - iOS 18.0, visionOS 2.0: `init(entity:configurationSpecifications:)`, `entity`, `configurationSpecifications`

### `TextureResource.Dimensions2DArray` — struct
  - iOS 18.0, visionOS 2.0: `static dimensions(width:height:length:)`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.DimensionsCube` — struct
  - iOS 18.0, visionOS 2.0: `static dimensions(faceSize:)`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.Dimensions3D` — struct
  - iOS 18.0, visionOS 2.0: `static dimensions(width:height:depth:)`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.Dimensions2D` — struct
  - iOS 18.0, visionOS 1.0: `static dimensions(width:height:)`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.Format` — struct
  - iOS 18.0, visionOS 1.0: `static color(_:pixelFormat:)`, `static normal(_:pixelFormat:)`, `static raw(pixelFormat:)`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.Contents` — struct
  - iOS 18.0, visionOS 1.0: `init(mipmapLevels:)`, conforms to Sendable

### `TextureResource.Contents.MipmapLevel` — struct
  - not iOS, not visionOS: `static mip(buffer:offset:size:bytesPerRow:)`
  - iOS 18.0, visionOS 1.0: `static mip(data:bytesPerRow:)`, `static mip(unsafeBuffer:offset:size:bytesPerRow:)`, conforms to Sendable
  - iOS 18.0, visionOS 2.0: `static mip(slices:)`, `static mip(data:bytesPerRow:bytesPerImage:)`, `static mip(unsafeBuffer:offset:size:bytesPerRow:bytesPerImage:)`

### `TextureResource.Contents.Slice` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `static slice(data:bytesPerRow:)`, `static slice(unsafeBuffer:offset:size:bytesPerRow:)`

### `TextureResource.Format.ColorSpace` — enum
  - iOS 18.0, visionOS 1.0: `.displayP3`, conforms to Equatable, Hashable, conforms to Sendable

### `TextureResource.Format.NormalEncoding` — enum
  - iOS 18.0, visionOS 1.0: `.xy`, `.wy`, conforms to Equatable, Hashable, conforms to Sendable

### `ActionEntityResolution` — enum (iOS 18.0, visionOS 2.0); conforms to Codable, Equatable
  - iOS 18.0, visionOS 2.0: `.entityPath(...)`, `.entityNamed(...)`, `static sourceEntity`

### `CameraFieldOfViewOrientation` — enum (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `.horizontal`, `.vertical`, conforms to Equatable, conforms to Hashable

### `OrthographicCameraComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 2.0: `near`, `far`, `scale`, `scaleDirection`, `init()`

### `HasPhysicsBody` — protocol (iOS 13.0); conforms to HasCollision
  - iOS 13.0: `addForce(_:relativeTo:)`, `addForce(_:at:relativeTo:)`, `addTorque(_:relativeTo:)`, `clearForcesAndTorques()`, `applyLinearImpulse(_:relativeTo:)`, `applyAngularImpulse(_:relativeTo:)`, `applyImpulse(_:at:relativeTo:)`, `physicsBody`, `resetPhysicsTransform(recursive:)`
  - deprecated: `resetPhysicsTransform(_:recursive:)`

### `OcclusionCullingComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `isEnabled`, `init(isEnabled:)`

### `HasCollision` — protocol (iOS 13.0); conforms to HasTransform
  - iOS 13.0: `collision`

### `AudioFileResource.Configuration` — struct
  - iOS 18.0, visionOS 1.0: `loadingStrategy`, `shouldLoop`, `shouldRandomizeStartTime`, `normalization`, `calibration`, `mixGroupName`, `init(loadingStrategy:shouldLoop:shouldRandomizeStartTime:normalization:calibration:mixGroupName:)`, conforms to Equatable, Hashable, Sendable

### `HasAnchoring` — protocol (iOS 13.0); conforms to Entity
  - iOS 13.0: `anchoring`, `anchorIdentifier`, `reanchor(_:preservingWorldTransform:)`

### `IKResource` — class (iOS 18.0, visionOS 2.0); conforms to Resource
  - iOS 18.0, visionOS 2.0: `solverDefinitions`, `init(rig:)`

### `LowLevelTexture` — class (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `descriptor`, `init(descriptor:)`, `read()`, `replace(using:)`, conforms to Sendable
  - iOS 27.0, visionOS 27.0: `init(deviceResource:using:)`, `replace(deviceResource:using:)`

### `LowLevelTexture.Descriptor` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(textureType:pixelFormat:width:height:depth:mipmapLevelCount:arrayLength:textureUsage:swizzle:)`, `textureType`, `pixelFormat`, `width`, `height`, `depth`, `mipmapLevelCount`, `arrayLength`, `textureUsage`, `swizzle`
  - iOS 27.0, visionOS 27.0: `init(_:)`

### `LowLevelDeviceResource` — class (iOS 27.0, visionOS 27.0)
  - not visionOS: `init(texture:)`
  - iOS 27.0, visionOS 27.0: `init(textureDescriptor:iosurface:plane:)`

### `LightmapComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `entityIndexInLightmapResource`, `lightmap`, `indirectIrradianceContributionScale`, `init(resource:)`

### `LightmapComponent.SurfaceExtractor` — class (not iOS, not visionOS)
  - not iOS, not visionOS: `init(lightmapRootEntity:)`, `extractSurfacesForAtlasSlice(mode:atlasTextureIndex:textureSliceIndex:cameraOutput:cameraTransform:cameraFOVDegrees:onComplete:)`, conforms to Sendable

### `LightmapComponent.SurfaceExtractor.ExtractionMode` — enum
  - not iOS, not visionOS: `.baseColor`, `.finalShadedColor`, conforms to Equatable, conforms to Hashable

### `LightmapComponent.FinalShadedColorBakeMaterial` — struct; conforms to Material
  - iOS 27.0, visionOS 27.0: `init()`

### `AudioResource.Normalization` — struct
  - iOS 18.0, visionOS 1.0: `static dynamic`, conforms to Equatable, Hashable, Sendable

### `SystemDependency` — enum (iOS 15.0); conforms to Equatable, Sendable
  - iOS 15.0: `.before(...)`, `.after(...)`

### `AnimationFillMode` — struct (iOS 15.0); conforms to OptionSet
  - iOS 15.0: `rawValue`, `static none`, `static forwards`, `static backwards`, `static both`, `init(rawValue:)`

### `AnimatableData` — protocol (iOS 15.0)

### `JointTransforms` — struct (iOS 15.0); conforms to BidirectionalCollection, MutableCollection, ExpressibleByArrayLiteral, Equatable, AnimatableData
  - iOS 15.0: `init()`, `init(arrayLiteral:)`, `init(_:)`, `subscript(index:)`, `startIndex`, `endIndex`, `index(after:)`, `index(before:)`
  - iOS 18.0, visionOS 2.0: conforms to Codable

### `BlendShapeWeights` — struct (iOS 18.0, visionOS 2.0); conforms to BidirectionalCollection, MutableCollection, ExpressibleByArrayLiteral, Equatable, AnimatableData
  - iOS 18.0, visionOS 2.0: `init()`, `init(arrayLiteral:)`, `init(_:)`, `subscript(index:)`, `startIndex`, `endIndex`, `index(after:)`, `index(before:)`, conforms to Codable

### `AnimationDefinition` — protocol (iOS 15.0)
  - iOS 15.0: `name`, `blendLayer`, `fillMode`, `bindTarget`, `trimStart`, `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`, `duration`, `trimmed(start:end:duration:)`, `repeated(count:)`, `repeatingForever()`

### `AnimationPlaybackController` — class (iOS 13.0); conforms to Hashable
  - iOS 13.0: `entity`, `isPaused`, `isComplete`, `pause()`, `resume()`, `stop()`, conforms to Sendable
  - iOS 15.0: `isValid`, `isPlaying`, `isStopped`, `speed`, `time`, `blendFactor`, `duration`, `clock`
  - iOS 18.0, visionOS 1.0: `stop(blendOutDuration:)`
  - iOS 26.0, visionOS 26.0: conforms to Observable

### `Entity.ForwardDirection` — enum (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `.negativeZ`, `.positiveZ`, conforms to Equatable, conforms to Hashable

### `LevelOfDetailComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init(levels:switchingAt:)`, `levels`, `strategy`, `levelSelection`, `static addByCameraDistance(to:levels:)`, `static addByScreenArea(to:levels:)`, `static addByResolutionMetric(to:levels:boundingBox:)`

### `LevelOfDetailComponent.SelectionStrategy` — struct
  - iOS 27.0, visionOS 27.0: `static resolutionMetric(switchingResolutions:boundingBox:)`, `static cameraDistance(_:)`, `static screenArea(_:)`

### `LevelOfDetailComponent.SelectionStrategy.ResolutionMetric` — struct
  - iOS 27.0, visionOS 27.0: `init(switchingResolutions:boundingBox:)`, `switchingResolutions`, `boundingBox`

### `LevelOfDetailComponent.SelectionStrategy.ResolutionMetric.DirectionalSwitchingResolutions` — struct
  - iOS 27.0, visionOS 27.0: `init(positiveX:negativeX:positiveY:negativeY:positiveZ:negativeZ:)`, `init()`, `positiveX`, `negativeX`, `positiveY`, `negativeY`, `positiveZ`, `negativeZ`

### `LevelOfDetailComponent.LevelSelection` — struct
  - iOS 27.0, visionOS 27.0: `static automatic`, `static fixed(_:)`

### `DynamicLightShadowComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `castsShadow`, `init(castsShadow:)`

### `MeshResource.GenerateTextOptions` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `containerFrame`, `init()`

### `MeshResource.ShapeExtrusionOptions` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init()`, `extrusionMethod`, `chamferRadius`, `boundaryResolution`, `chamferResolution`, `chamferMode`, `materialAssignment`

### `MeshResource.ShapeExtrusionOptions.CurveStrokeResolution` — enum; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `.uniformSegmentsPerSpan(...)`

### `MeshResource.ShapeExtrusionOptions.ChamferMode` — enum; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `.front`, `.back`, `.both`, conforms to Equatable, conforms to Hashable

### `MeshResource.ShapeExtrusionOptions.MaterialAssignment` — struct; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `init(assignAll:)`, `init(front:back:extrusion:frontChamfer:backChamfer:)`

### `MeshResource.ShapeExtrusionOptions.ExtrusionMethod` — enum; conforms to Sendable
  - iOS 18.0, visionOS 2.0: `.linear(...)`, `.tracePositions(...)`, `.traceTransforms(...)`

### `HasPerspectiveCamera` — protocol (iOS 13.0); conforms to HasTransform
  - iOS 13.0: `camera`

### `CustomMaterialError` — enum (iOS 15.0, not visionOS); conforms to Error
  - iOS 15.0, not visionOS: `.geometryModifierFunctionNotFound`, `.surfaceShaderFunctionNotFound`, `.defaultSurfaceShaderForMaterialNotFound`, conforms to Equatable, conforms to Hashable

### `MaterialFunction` — protocol (iOS 15.0)
  - iOS 15.0: `name`, `library`
  - iOS 18.0, visionOS 2.0: `constantValues`

### `CustomMaterial.LightingModel` — enum (iOS 15.0); conforms to Hashable, Sendable
  - iOS 15.0: `.lit`, `.unlit`, `.clearcoat`

### `CustomMaterial.Custom` — struct (iOS 15.0)
  - iOS 15.0: `value`, `texture`, `init(value:texture:)`

### `HasSceneUnderstanding` — protocol (iOS 13.4, visionOS 1.0); conforms to Entity
  - iOS 13.4, visionOS 1.0: `sceneUnderstanding`

### `ParticleEmitterComponent.EmitterShape` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.point`, `.plane`, `.box`, `.sphere`, `.cone`, `.cylinder`, `.torus`

### `ParticleEmitterComponent.BirthLocation` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.surface`, `.volume`, `.vertices(...)`

### `ParticleEmitterComponent.BirthDirection` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.world`, `.local`, `.normal`

### `ParticleEmitterComponent.SpawnOccasion` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.onBirth`, `.onUpdate`, `.onDeath`

### `ParticleEmitterComponent.SimulationSpace` — enum; conforms to Codable
  - iOS 18.0, visionOS 1.0: `.local`, `.global`, conforms to Equatable, conforms to Hashable

### `ParticleEmitterComponent.SimulationState` — enum; conforms to Codable
  - iOS 18.0, visionOS 1.0: `.play`, `.pause`, `.stop`, conforms to Equatable, conforms to Hashable

### `ParticleEmitterComponent.ParticleEmitter` — struct
  - iOS 18.0, visionOS 1.0: `birthRate`, `birthRateVariation`, `dampingFactor`, `acceleration`, `spreadingAngle`, `size`, `sizeVariation`, `billboardMode`, `mass`, `massVariation`, `lifeSpan`, `lifeSpanVariation`, `angle`, `angleVariation`, `angularSpeed`, `angularSpeedVariation`, `opacityCurve`, `sizeMultiplierAtEndOfLifespan`, `sizeMultiplierAtEndOfLifespanPower`, `colorEvolutionPower`, `noiseStrength`, `noiseScale`, `noiseAnimationSpeed`, `attractionStrength`, `attractionCenter`, `vortexStrength`, `vortexDirection`, `isLightingEnabled`, `stretchFactor`, `sortOrder`, `blendMode`, `image`, `imageSequence`, `init()`, conforms to Codable

### `ParticleEmitterComponent.ParticleEmitter.BillboardMode` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.billboard`, `.billboardYAligned`, `.free(...)`

### `ParticleEmitterComponent.ParticleEmitter.OpacityCurve` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.linearFadeOut`, `.linearFadeIn`, `.gradualFadeInOut`, `.quickFadeInOut`, `.easeFadeIn`, `.easeFadeOut`, `.constant`

### `ParticleEmitterComponent.ParticleEmitter.SortOrder` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.increasingDepth`, `.decreasingDepth`, `.increasingID`, `.decreasingID`, `.increasingAge`, `.decreasingAge`, `.unsorted`

### `ParticleEmitterComponent.ParticleEmitter.BlendMode` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.alpha`, `.opaque`, `.additive`

### `ParticleEmitterComponent.ParticleEmitter.ImageSequence` — struct; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `rowCount`, `columnCount`, `initialFrame`, `initialFrameVariation`, `frameRate`, `frameRateVariation`, `animationMode`, `init()`

### `ParticleEmitterComponent.ParticleEmitter.ImageSequence.AnimationRepeatMode` — enum; conforms to Codable, Equatable, Hashable
  - iOS 18.0, visionOS 1.0: `.playOnce`, `.looping`, `.autoReverse`

### `LowLevelInstanceData` — class
  - unannotated: `instanceCapacity`, `instanceCount`, `init(instanceCount:)`, `init(instanceCount:instanceCapacity:)`, `read(using:)`, `replace(using:)`, `withTransforms(_:)`, `withMutableTransforms(_:)`, `replaceMutableTransforms(_:)`

### `MeshInstancesComponent` — struct (iOS 26.0, visionOS 26.0); conforms to Component
  - iOS 26.0, visionOS 26.0: `init()`, `init(mesh:modelID:instances:bounds:)`, `subscript(partIndex:)`

### `MeshInstancesComponent.Part` — struct
  - iOS 26.0, visionOS 26.0: `data`, `bounds`, `init(data:bounds:)`

### `PortalComponent.SurfaceStyle` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `width`, `height`, `init(width:height:)`

### `PortalComponent.BoundaryStyle` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `static infinitePlane()`, `static enclosingBox(depth:)`

### `PortalComponent.BoundaryMode` — enum; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `.none`, `.clippingOnly`, `.crossingOnly`, `.clippingAndCrossing`

### `PortalComponent.Portal` — struct
  - iOS 27.0, visionOS 27.0: `portalEntity`, `worldEntity`

### `ForceEffectBounds` — enum (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `.sphere(...)`

### `SpatialForceFalloff` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `init(bounds:rate:distanceOffset:)`, `distanceOffset`, `bounds`, `rate`

### `TimedForceFalloff` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `init(duration:rate:)`, `duration`, `rate`

### `ForceMode` — enum (iOS 18.0, visionOS 2.0); conforms to Codable, Equatable
  - iOS 18.0, visionOS 2.0: `.force`, `.acceleration`, `.impulse`, `.velocity`, conforms to Hashable

### `ForceEffectProtocol` — protocol (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `parameterTypes`, `forceMode`, `update(parameters:)`, `static register(_:)`, conforms to Decodable, Self : Encodable

### `ForceEffectBase` — protocol (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `assoc ForceEffectType`, `effect`, `spatialFalloff`, `timedFalloff`, `position`, `orientation`, `strengthScale`, `mask`

### `ForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectBase where ForceEffectType : ForceEffectProtocol
  - iOS 18.0, visionOS 2.0: `init(effect:strengthScale:spatialFalloff:timedFalloff:position:orientation:mask:)`, `effect`, `spatialFalloff`, `timedFalloff`, `position`, `orientation`, `strengthScale`, `mask`

### `PhysicsBodyParameterTypes` — struct (iOS 18.0, visionOS 2.0); conforms to Codable, OptionSet
  - iOS 18.0, visionOS 2.0: `static position`, `static orientation`, `static velocity`, `static angularVelocity`, `static distance`, `static mass`, `static inertiaTensor`, `rawValue`, `init(rawValue:)`

### `UnsafeForceEffectBuffer` — struct (iOS 18.0, visionOS 2.0); conforms to Sequence
  - iOS 18.0, visionOS 2.0: `subscript(index:)`, `makeIterator()`, `count`

### `UnsafeForceEffectBuffer.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `ForceEffectParameters` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `entity`, `physicsBodyCount`, `fixedDeltaTime`, `elapsedTime`, `positions`, `orientations`, `velocities`, `angularVelocities`, `distances`, `masses`, `inertiaTensors`, `setForce(_:index:)`, `setTorque(_:index:)`

### `ForceEffectEvent` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol
  - iOS 18.0, visionOS 2.0: `effect`, `parameters`

### `ForceEffectComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `effects`, `init(effects:simulationState:)`, `init(effect:)`, `simulationState`

### `ForceEffectComponent.SimulationState` — enum
  - iOS 18.0, visionOS 2.0: `.start`, `.pause`, `.resume`, conforms to Equatable, conforms to Hashable

### `ConstantForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:direction:)`, `update(parameters:)`, `strength`, `direction`, `parameterTypes`, `forceMode`

### `ConstantRadialForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:)`, `update(parameters:)`, `strength`, `parameterTypes`, `forceMode`

### `VortexForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:axis:)`, `update(parameters:)`, `strength`, `axis`, `parameterTypes`, `forceMode`

### `DragForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:)`, `update(parameters:)`, `strength`, `parameterTypes`, `forceMode`

### `TurbulenceForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:smoothness:speed:)`, `update(parameters:)`, `strength`, `smoothness`, `speed`, `parameterTypes`, `forceMode`

### `RadialForceEffect` — struct (iOS 18.0, visionOS 2.0); conforms to ForceEffectProtocol, Codable
  - iOS 18.0, visionOS 2.0: `init(strength:restDistance:)`, `update(parameters:)`, `strength`, `restDistance`, `parameterTypes`, `forceMode`

### `AudioPlaybackGroupController` — class
  - unannotated: `resourcesAndEntities`, `play()`, `pause()`, `stop()`, `isPlaying`, `speed`, `gain`, `fade(to:duration:)`, `seek(to:)`
  - iOS 27.0, visionOS 27.0: conforms to Identifiable, `id`, `play(at:)`, conforms to Sendable

### `MaterialParameters` — struct (iOS 15.0)

### `MaterialParameters.Texture` — struct
  - iOS 15.0: `resource`, `sampler`, `uvIndex`, `init(_:sampler:)`, `init(_:)`
  - iOS 18.0, visionOS 2.0: `swizzle`
  - iOS 18.0, visionOS 1.0: conforms to Equatable

### `MaterialParameters.Texture.Sampler` — struct
  - iOS 15.0: `init()`, `init(_:)`, `modify(_:)`, `access(_:)`
  - iOS 18.0, visionOS 1.0: conforms to Equatable

### `MaterialParameters.Handle` — struct (iOS 18.0, visionOS 1.0)
  - iOS 26.0, visionOS 26.0: conforms to Hashable, Equatable

### `MaterialParameters.Value` — enum (iOS 18.0, visionOS 1.0)
  - visionOS 2.0: `.texture(...)`
  - iOS 18.0, visionOS 1.0: `.textureResource(...)`, `.float(...)`, `.simd2Float(...)`, `.simd3Float(...)`, `.simd4Float(...)`, `.color(...)`, `.float2x2(...)`, `.float3x3(...)`, `.float4x4(...)`, `.bool(...)`, `.int(...)`
  - iOS 18.0, visionOS 2.0: conforms to Equatable

### `PhysicsMaterialResource` — class; conforms to Resource
  - unannotated: `static default`, `static generate(friction:restitution:)`
  - iOS 13.4: `static generate(staticFriction:dynamicFriction:restitution:)`

### `CameraControls` — struct (iOS 18.0, visionOS 2.0); conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `static none`, `static tilt`, `static pan`, `static orbit`, `static dolly`

### `GeometricPinsComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `init()`, `pins`, `subscript(name:)`, `removePin(named:)`, `set(pin:)`

### `ClippingComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component, Equatable
  - iOS 27.0, visionOS 27.0: `bounds`, `featheredEdge`, `shouldClipChildren`, `shouldClipSelf`, `init(bounds:)`

### `ClippingComponent.FeatheredEdge` — struct; conforms to Equatable
  - iOS 27.0, visionOS 27.0: `falloff`, `positiveEdgeInset`, `negativeEdgeInset`, `init(symmetricEdgeInset:falloff:)`, `static none`

### `ClippingComponent.FeatheredEdge.Falloff` — enum
  - iOS 27.0, visionOS 27.0: `.linear`, `.cubic`, conforms to Equatable, conforms to Hashable

### `HasSpotLight` — protocol (iOS 13.0, visionOS 2.0); conforms to HasTransform
  - iOS 13.0, visionOS 2.0: `light`, `shadow`

### `VideoPlayerComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component
  - iOS 18.0, visionOS 1.0: `desiredViewingMode`, `viewingMode`, `playerScreenSize`, `screenVideoDimension`, `avPlayer`, `init(avPlayer:)`
  - not iOS, visionOS 2.0: `desiredImmersiveViewingMode`, `immersiveViewingMode`
  - not iOS, visionOS 27.0: `portalSize`
  - iOS 18.0, visionOS 26.0: `currentRenderingStatus`
  - not iOS, visionOS 1.0: `isPassthroughTintingEnabled`
  - iOS 18.0, visionOS 2.0: `videoRenderer`, `init(videoRenderer:)`

### `VideoPlayerComponent.ImmersiveViewingMode` — enum (not iOS, visionOS 2.0); conforms to Sendable
  - not iOS, visionOS 2.0: `.portal`, `.full`, conforms to Equatable, conforms to Hashable
  - visionOS 26.0: `.progressive`

### `VideoPlayerComponent.VideoComfortMitigation` — enum (not iOS, visionOS 26.0)
  - not iOS, visionOS 26.0: `.play`, `.pause`, `.reduceImmersion`, conforms to Equatable, conforms to Hashable

### `VideoPlayerComponent.RenderingStatus` — enum (iOS 18.0, visionOS 26.0); conforms to Sendable
  - iOS 18.0, visionOS 26.0: `.loading`, `.ready`, conforms to Equatable, conforms to Hashable

### `MeshDeformerExecutionMode` — enum (iOS 27.0, visionOS 27.0); conforms to Sendable, Equatable, Codable
  - iOS 27.0, visionOS 27.0: `.gpu`, `.cpu`, conforms to Hashable

### `MeshDeformerOptions` — struct (iOS 27.0, visionOS 27.0); conforms to Sendable, Equatable, Codable
  - iOS 27.0, visionOS 27.0: `cadence`, `inputSpec`, `outputSpec`, `init()`, `init(cadence:inputSpec:outputSpec:)`

### `MeshDeformerOptions.Cadence` — enum; conforms to Sendable, Equatable, Codable
  - iOS 27.0, visionOS 27.0: `.onDemand`, `.everyFrame`, conforms to Hashable

### `MeshDeformerVertexOptions` — struct (iOS 27.0, visionOS 27.0); conforms to OptionSet, Sendable, Equatable, Codable, Hashable
  - iOS 27.0, visionOS 27.0: `static positions`, `static normals`, `static tangents`, `static bitangents`, `static uvs`, `static uv1s`, `static uv2s`, `static uv3s`, `static uv4s`, `static uv5s`, `static uv6s`, `static uv7s`, `static tangentFrame`, `static all`, `rawValue`, `init(rawValue:)`

### `MeshDeformParameter` — struct (iOS 27.0, visionOS 27.0)
  - iOS 27.0, visionOS 27.0: `inputBuffers`, `outputBuffers`

### `MeshDeformParameter.VertexBuffers` — struct
  - iOS 27.0, visionOS 27.0: `positions`, `normals`, `tangents`, `bitangents`, `uvs`, `uv1s`, `uv2s`, `uv3s`, `uv4s`, `uv5s`, `uv6s`, `uv7s`, `count`

### `MeshDeformParameter.VertexBuffers.Data` — struct
  - iOS 27.0, visionOS 27.0: `buffer`, `format`, `offset`, `stride`

### `MeshDeformer` — protocol (iOS 27.0, visionOS 27.0); conforms to Decodable, Encodable, Equatable, Sendable
  - iOS 27.0, visionOS 27.0: `static mode`, `mode`, `options`, `type`, `deform(parameter:)`, `static type`, `deform(parameter:encoder:)`, `isDeformerEqual(other:)`

### `AccessibilityComponent` — struct (iOS 17.0); conforms to Component
  - iOS 17.0: `isAccessibilityElement`, `label`, `value`, `customContent`, `systemActions`, `customActions`, `init()`

### `AccessibilityComponent.CustomContent` — struct; conforms to Equatable
  - iOS 17.0: `label`, `value`, `importance`, `init(label:value:importance:)`

### `AccessibilityComponent.SupportedActions` — struct; conforms to OptionSet
  - iOS 17.0: `rawValue`, `static activate`, `static increment`, `static decrement`, `init(rawValue:)`

### `AudioResource.Calibration` — struct
  - iOS 18.0, visionOS 1.0: `static relative(dBSPL:)`, `static absolute(dBSPL:)`, conforms to Equatable, Hashable, Sendable

### `ShaderGraphMaterial` — struct (iOS 18.0, visionOS 1.0); conforms to Material, @unchecked Sendable
  - iOS 18.0, visionOS 1.0: `init(named:from:)`, `init(named:from:in:)`, `init(materialXLabel:data:)`, `static parameterHandle(name:)`, `setParameter(handle:value:)`, `getParameter(handle:)`, `setParameter(name:value:)`, `getParameter(name:)`, `parameterNames`, `triangleFillMode`
  - iOS 27.0, visionOS 27.0: `program`, `init(program:)`
  - iOS 18.0, visionOS 2.0: `faceCulling`, `writesDepth`, `readsDepth`

### `ShaderGraphMaterial.LoadError` — enum; conforms to LocalizedError
  - iOS 18.0, visionOS 1.0: `.invalidTypeFound`, `.materialNameNotFound`, `.invalidURL`, `.resourceShareFailed`, conforms to Equatable, conforms to Hashable

### `ShaderGraphMaterial.Program` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `init(descriptor:)`, `descriptor`

### `ShaderGraphMaterial.Program.Descriptor` — struct; conforms to Equatable
  - iOS 27.0, visionOS 27.0: `shaderGraph`, `lightingModel`, `isColorDitheringEnabled`, `blendMode`, `inputValues`, `constantValues`, `init(inferredFrom:inputValues:constantValues:)`, `init(shaderGraph:lightingModel:isColorDitheringEnabled:blendMode:inputValues:constantValues:)`

### `LitLightingModel` — struct (iOS 27.0, visionOS 27.0); conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `diffuseModel`, `specularModel`, `isSubsurfaceScatteringEnabled`, `isMultiscatteringEnabled`, `isBentNormalEnabled`, `isClearcoatEnabled`, `init()`

### `LitLightingModel.DiffuseModel` — enum; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `.hammon`, `.lambertian`, `.orenNayar`

### `LitLightingModel.SpecularModel` — enum; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `.ggx`, `.blinnPhong`, `.sheen`, `.anisotropicGGX`

### `HairLightingModel` — struct (iOS 27.0, visionOS 27.0); conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `init()`

### `UnlitLightingModel` — struct (iOS 27.0, visionOS 27.0); conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `isTonemappingEnabled`, `init()`

### `LightingModel` — enum (iOS 27.0, visionOS 27.0); conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `.lit(...)`, `.hair(...)`, `.unlit(...)`, `static lit(diffuseModel:specularModel:isSubsurfaceScatteringEnabled:isMultiscatteringEnabled:isBentNormalEnabled:isClearcoatEnabled:)`, `static hair()`, `static unlit(isTonemappingEnabled:)`

### `AntialiasingMode` — enum (iOS 18.0, visionOS 2.0); conforms to Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `.none`, `.multisample4X`

### `DiffuseProbeResource` — class; conforms to Resource, Sendable
  - unannotated: `init(positions:coefficients:tetrahedronIndices:)`

### `EventSubscription` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `cancel()`, `subscribe(to:)`

### `ShapeResource` — class; conforms to Resource, Hashable, Sendable
  - iOS 18.0, visionOS 1.0: `bounds`, `static generateStaticMesh(positions:faceIndices:)`
  - iOS 13.0: `offsetBy(rotation:)`, `offsetBy(translation:)`, `offsetBy(rotation:translation:)`, `static generateBox(size:)`, `static generateBox(width:height:depth:)`, `static generateCapsule(height:radius:)`, `static generateConvex(from:)`, `static generateSphere(radius:)`
  - iOS 18.0, visionOS 2.0: `static generateStaticMesh(from:)`

### `ShapeResourceError` — enum (iOS 18.0, visionOS 1.0); conforms to LocalizedError
  - iOS 18.0, visionOS 1.0: `.staticMeshGenerationFailed`, `.convexPolyhedronGenerationFailed`, `errorDescription`, conforms to Equatable, conforms to Hashable

### `ImagePresentationComponent.ViewingMode` — struct; conforms to Sendable, Hashable
  - not iOS, visionOS 26.0: `static mono`, `static spatialStereo`, `static spatialStereoImmersive`, `static spatial3D`, `static spatial3DImmersive`

### `SkeletalPoseSet` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `init()`, `default`, `count`, `isEmpty`, `subscript(poseID:)`, `contains(_:)`, `set(_:)`, conforms to Sequence, `makeIterator()`, conforms to Collection, `startIndex`, `endIndex`, `index(of:)`, `subscript(index:)`, `index(after:)`

### `SkeletalPoseSet.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `CollisionCastQueryType` — enum (iOS 13.0); conforms to Hashable
  - iOS 13.0: `.nearest`, `.all`, `.any`

### `CollisionGroup` — struct (iOS 13.0); conforms to OptionSet
  - iOS 13.0: `rawValue`, `static default`, `static all`, `init(rawValue:)`
  - iOS 13.4: `static sceneUnderstanding`

### `CollisionFilter` — struct (iOS 13.0); conforms to Equatable
  - iOS 13.0: `static default`, `static sensor`, `group`, `mask`, `init(group:mask:)`

### `CollisionCastHit` — struct (iOS 13.0); conforms to Equatable
  - iOS 13.0: `entity`, `position`, `normal`, `distance`
  - iOS 18.0, visionOS 1.0: `triangleHit`, `shapeIndex`

### `CollisionCastHit.TriangleHit` — struct; conforms to Equatable
  - iOS 18.0, visionOS 1.0: `faceIndex`, `uv`

### `AnimationStateProtocol` — protocol (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `assoc ValueType`, `defaultSource`, `defaultTarget`, `deltaTime`, `evaluationTime`, `normalizedTime`, `storeAnimatedValue(_:)`

### `AnimationState` — struct (iOS 18.0, visionOS 2.0); conforms to AnimationStateProtocol where Value : AnimatableData
  - iOS 18.0, visionOS 2.0: `defaultSource`, `defaultTarget`, `storeAnimatedValue(_:)`, `deltaTime`, `evaluationTime`, `normalizedTime`, `defaultSourceJoints(index:count:transforms:)`, `defaultTargetJoints(index:count:transforms:)`, `storeAnimatedJoints(transforms:jointIndex:)`

### `MeshScope` — struct (iOS 27.0, visionOS 27.0); conforms to Sendable, Codable, Equatable, Hashable, CustomStringConvertible
  - iOS 27.0, visionOS 27.0: `static all`, `static model(name:part:)`, `static instance(name:part:)`, `isAll`, `isInstance`, `isModel`, `description`

### `BlendShapeDeformer` — struct (iOS 27.0, visionOS 27.0); conforms to MeshDeformer
  - iOS 27.0, visionOS 27.0: `isDeformerEqual(other:)`, `static type`, `deform(parameter:encoder:)`, `init()`

### `BoundingBoxCalculator` — struct (iOS 27.0, visionOS 27.0); conforms to MeshDeformer
  - iOS 27.0, visionOS 27.0: `isDeformerEqual(other:)`, `static type`, `deform(parameter:encoder:)`, `init()`

### `SubdivisionSurfaceDeformer` — struct (iOS 27.0, visionOS 27.0); conforms to MeshDeformer
  - iOS 27.0, visionOS 27.0: `isDeformerEqual(other:)`, `static type`, `deform(parameter:encoder:)`, `init()`

### `RenormalizingDeformer` — struct (iOS 27.0, visionOS 27.0); conforms to MeshDeformer
  - iOS 27.0, visionOS 27.0: `isDeformerEqual(other:)`, `static type`, `deform(parameter:encoder:)`, `init()`

### `SkinningDeformer` — struct (iOS 27.0, visionOS 27.0); conforms to MeshDeformer
  - iOS 27.0, visionOS 27.0: `isDeformerEqual(other:)`, `skinsTangentFrame`, `static type`, `deform(parameter:encoder:)`, `init(skinsTangentFrame:)`

### `PerspectiveCameraComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `near`, `far`, `fieldOfViewInDegrees`, `init(near:far:fieldOfViewInDegrees:)`
  - iOS 18.0, visionOS 2.0: `fieldOfViewOrientation`, `init(near:far:fieldOfViewInDegrees:fieldOfViewOrientation:)`

### `PhotogrammetrySession` — class (not visionOS)
  - not visionOS: `init(input:configuration:)`, `process(requests:)`, `cancel()`, `activeRequests`, `isProcessing`, `configuration`, `outputs`
  - iOS 17.0: `static limits`, `static isSupported`
  - iOS 17.0, not visionOS: conforms to Identifiable, `id`

### `PhotogrammetrySession.Outputs` — struct; conforms to AsyncSequence
  - not visionOS: `makeAsyncIterator()`

### `PhotogrammetrySession.Outputs.Iterator` — struct; conforms to AsyncIteratorProtocol
  - not visionOS: `next()`

### `OrientedBoundingBox` — struct (iOS 17.0, not visionOS); conforms to Hashable
  - iOS 17.0, not visionOS: `orientation`, `boundingBox`, `init(orientation:boundingBox:)`, conforms to Sendable

### `ShaderGraphMaterial.Error` — enum; conforms to LocalizedError
  - iOS 18.0, visionOS 1.0: `.incorrectTypeForParameterName`, `.parameterNameNotFound`, conforms to Equatable, conforms to Hashable

### `HasPointLight` — protocol (iOS 13.0, visionOS 2.0); conforms to HasTransform
  - iOS 13.0, visionOS 2.0: `light`

### `LoadRequest` — class (deprecated); conforms to Publisher
  - deprecated: `result`, `subscribe(_:)`, `receive(subscriber:)`

### `SpatialTrackingSession` — class (iOS 15.0, visionOS 2.0); conforms to Sendable
  - iOS 15.0, visionOS 2.0: `init()`
  - iOS 18.0, visionOS 2.0: `run(_:)`, `stop()`

### `SpatialTrackingSession.Configuration` — struct
  - not iOS, visionOS 2.0: `init(tracking:)`
  - not iOS, visionOS 26.0: `init(tracking:sceneUnderstanding:)`
  - iOS 18.0, not visionOS: `init(tracking:sceneUnderstanding:camera:)`
  - iOS 18.0, visionOS 2.0: conforms to CustomStringConvertible, `description`, `debugDescription`

### `SpatialTrackingSession.Configuration.AnchorCapability` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `static world`, `static plane`, `static image`, `static object`, conforms to CustomStringConvertible, `description`, `debugDescription`
  - not iOS, visionOS 2.0: `static hand`
  - not iOS, visionOS 26.0: `static accessory`
  - iOS 18.0, not visionOS: `static camera`, `static face`, `static body`

### `SpatialTrackingSession.UnavailableCapabilities` — struct; conforms to Sendable
  - iOS 15.0, visionOS 2.0: `init()`
  - iOS 18.0, visionOS 2.0: `anchor`
  - iOS 18.0, visionOS 26.0: `sceneUnderstanding`
  - iOS 18.0, not visionOS: `missingCameraAuthorization`

### `SpatialTrackingSession.Configuration.SceneUnderstandingCapability` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 26.0: `static collision`, `static physics`, conforms to CustomStringConvertible, `description`, `debugDescription`
  - iOS 18.0, not visionOS: `static shadow`, `static occlusion`

### `SpatialTrackingSession.Configuration.Camera` — enum (not visionOS)
  - not visionOS: `.back`, `.front`
  - iOS 18.0, not visionOS: conforms to Equatable, conforms to Hashable

### `AttachedTransformComponent` — struct (iOS 26.0, visionOS 26.0); conforms to Component
  - iOS 26.0, visionOS 26.0: `init(source:target:)`, `target`, `source`

### `Entity.WriteOptions` — struct (iOS 26.0, visionOS 26.0); conforms to ExpressibleByArrayLiteral, Hashable, Sendable
  - iOS 26.0, visionOS 26.0: `init(arrayLiteral:)`
  - iOS 27.0, visionOS 27.0: `static preferSmallTextureFiles(quality:)`, `static preferFastExport`

### `Entity.WriteOptions.TextureQuality` — struct (iOS 27.0, visionOS 27.0); conforms to Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `static standard`, `static medium`, `static low`

### `PhysicsBodyMode` — enum (iOS 27.0, visionOS 27.0); conforms to Hashable
  - iOS 27.0, visionOS 27.0: `.static`, `.kinematic`, `.dynamic`

### `PhysicsMassProperties` — struct (iOS 13.0); conforms to Equatable
  - iOS 13.0: `static default`, `mass`, `inertia`, `centerOfMass`, `init()`, `init(mass:inertia:centerOfMass:)`, `init(shape:density:)`, `init(shape:mass:)`

### `ReferenceComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `loadingPolicy`, `state`, `reference`, `init(named:at:loadingPolicy:)`, `init(named:in:loadingPolicy:)`, `init(named:loadingPolicy:)`, `static loadReference(at:)`, `static releaseReference(at:)`

### `ReferenceComponent.LoadingPolicy` — enum
  - iOS 18.0, visionOS 2.0: `.immediate`, `.onDemand`, conforms to Equatable, conforms to Hashable

### `ReferenceComponent.ReferenceState` — enum
  - iOS 18.0, visionOS 2.0: `.notLoaded`, `.loading`, `.loaded`, conforms to Equatable, conforms to Hashable

### `AnimationHandoffType` — struct (iOS 18.0, visionOS 1.0); conforms to Equatable
  - iOS 18.0, visionOS 1.0: `static snapshotAndReplace(applyToAllLayers:)`, `static replace(applyToAllLayers:)`, `static compose`, `static stop`, `static default`
  - iOS 18.0, visionOS 2.0: conforms to Codable

### `EntityGeometricPins` — struct (iOS 18.0, visionOS 2.0); conforms to Sequence
  - iOS 18.0, visionOS 2.0: `subscript(name:)`, `set(named:position:orientation:)`, `set(named:position:orientation:relativeTo:)`, `set(named:skeletalJointName:position:orientation:)`, `remove(named:)`, `count`, `isEmpty`, `makeIterator()`, `entity`, conforms to Sendable

### `EntityGeometricPins.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `PortalMaterial.Program` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `descriptor`, `init(descriptor:)`

### `PortalMaterial.Program.Descriptor` — struct; conforms to Equatable
  - iOS 27.0, visionOS 27.0: `shaderGraph`, `inputValues`, `constantValues`, `init(shaderGraph:inputValues:constantValues:)`

### `PhysicsSimulationComponent` — struct (iOS 18.0, visionOS 1.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 2.0: `solverIterations`
  - iOS 18.0, visionOS 1.0: `static nearestSimulationEntity(for:)`, `init()`, `gravity`, `collisionOptions`, `clock`

### `PhysicsSimulationComponent.CollisionOptions` — struct; conforms to OptionSet
  - iOS 18.0, visionOS 1.0: `static none`, `static reportKinematicVsStatic`, `static reportKinematicVsKinematic`, `static all`, `rawValue`, `init(rawValue:)`

### `PhysicsSimulationComponent.SolverIterations` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable
  - iOS 18.0, visionOS 2.0: `init(positionIterations:velocityIterations:)`, `positionIterations`, `velocityIterations`

### `SkeletalPose` — struct (iOS 18.0, visionOS 2.0); conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `id`, `jointNames`, `jointTransforms`, `subscript(joint:)`, `init(id:from:)`, `init(id:joints:)`

### `AnimationResource` — class (iOS 13.0); conforms to Resource
  - iOS 13.0: `name`, `repeat(duration:)`, `repeat(count:)`
  - iOS 15.0: `static group(with:)`, `static sequence(with:)`, `static generate(with:)`, `store(in:)`, `definition`
  - iOS 18.0, visionOS 2.0: `static makeActionAnimation(for:duration:name:bindTarget:blendLayer:repeatMode:fillMode:trimStart:trimEnd:trimDuration:offset:delay:speed:)`

### `AnimationRepeatMode` — enum (iOS 15.0)
  - iOS 15.0: `.none`, `.repeat`, `.cumulative`, `.autoReverse`, conforms to Equatable, conforms to Hashable

### `BehaviorTreeComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `behaviorTree`, `availableBehaviorTrees`, `init(behaviorTree:availableBehaviorTrees:)`

### `BehaviorTreeActionHandler` — protocol (iOS 27.0, visionOS 27.0); conforms to ActionHandlerProtocol
  - iOS 27.0, visionOS 27.0: `actionStartedWithResult(event:)`, `actionUpdatedWithResult(event:)`, `actionEndedWithResult(event:)`, `actionSkippedWithResult(event:)`, `actionPausedWithResult(event:)`, `actionResumedWithResult(event:)`, `actionTerminatedWithResult(event:)`, `actionStarted(event:)`, `actionUpdated(event:)`, `actionEnded(event:)`, `actionSkipped(event:)`, `actionPaused(event:)`, `actionResumed(event:)`, `actionTerminated(event:)`

### `BehaviorTreeAction` — protocol (iOS 27.0, visionOS 27.0); conforms to EntityAction
  - iOS 27.0, visionOS 27.0: `static subscribe(to:_:)`

### `CollisionComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `shapes`, `mode`, `filter`, `init(shapes:mode:filter:)`
  - iOS 18.0, visionOS 1.0: `init(shapes:isStatic:filter:)`, `isStatic`, `init(shapes:mode:collisionOptions:filter:)`, `collisionOptions`

### `CollisionComponent.Mode` — enum
  - iOS 13.0: `.default`, `.trigger`, conforms to Equatable, conforms to Hashable
  - iOS 18.0, visionOS 1.0: `.colliding`

### `CollisionComponent.CollisionOptions` — struct; conforms to OptionSet
  - iOS 18.0, visionOS 1.0: `static none`, `static static`, `static fullContactInformation`, `rawValue`, `init(rawValue:)`

### `DiffuseLightProbeReceiverComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component, Equatable
  - iOS 27.0, visionOS 27.0: `probeGroup`, `init(probeGroup:)`

### `NavigationMeshComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init(navigationMeshes:)`, `navigationMeshes`

### `NavigationComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init(layer:filter:)`, `filter`, `layer`

### `NavigationComponent.Filter` — struct
  - iOS 27.0, visionOS 27.0: `areaCosts`, `ignoreFlags`, `includeFlags`, `init()`

### `NavigationController` — struct (iOS 27.0, visionOS 27.0)
  - iOS 27.0, visionOS 27.0: `init(entity:)`, `requestPath(to:)`, `requestPath(from:to:)`, `computePath(to:)`, `computePath(from:to:)`, `stopPathfind()`, `pathfindStatus`, `currentPath`

### `NavigationController.PathfindStatus` — enum
  - iOS 27.0, visionOS 27.0: `.none`, `.inProgress`, `.failed`, `.succeeded`, conforms to Equatable, conforms to Hashable

### `AnchoringComponent` — struct (iOS 13.0); conforms to Component, Equatable
  - iOS 13.0: `target`, `init(_:)`
  - iOS 18.0, visionOS 1.0: `trackingMode`, `init(_:trackingMode:)`
  - iOS 18.0, visionOS 2.0: `init(_:trackingMode:physicsSimulation:)`, `physicsSimulation`

### `AnchoringComponent.Target` — enum; conforms to Hashable
  - not visionOS: `.camera`, `.anchor(...)`, `.object(...)`, `.face`, `.body`
  - iOS 13.0: `.world(...)`, `.plane(...)`, `.image(...)`
  - iOS 18.0, visionOS 2.0: `.referenceImage(...)`, `.referenceObject(...)`
  - not iOS, visionOS 1.0: `.hand(...)`, `.head`
  - not iOS, visionOS 26.0: `.accessory(...)`

### `AnchoringComponent.Target.Alignment` — struct; conforms to OptionSet
  - iOS 13.0: `static horizontal`, `static vertical`, `static any`, `rawValue`, `init(rawValue:)`

### `AnchoringComponent.Target.Classification` — struct; conforms to OptionSet
  - iOS 13.0: `static wall`, `static floor`, `static ceiling`, `static table`, `static seat`, `static any`, `rawValue`, `init(rawValue:)`

### `AnchoringComponent.Target.Chirality` — enum (not iOS, visionOS 1.0); conforms to Hashable
  - not iOS, visionOS 1.0: `.right`, `.left`, `.either`
  - not visionOS: `.any`
  - not iOS, visionOS 27.0: conforms to Codable

### `AnchoringComponent.Target.HandLocation` — struct (not iOS, visionOS 1.0); conforms to Hashable
  - not iOS, visionOS 1.0: `static wrist`, `static palm`, `static indexFingerTip`, `static thumbTip`, `static aboveHand`
  - not iOS, visionOS 2.0: `static joint(for:)`

### `AnchoringComponent.TrackingMode` — struct; conforms to Hashable
  - iOS 18.0, visionOS 1.0: `static once`, `static continuous`
  - visionOS 2.0: `static predicted`

### `AnchoringComponent.ObjectAnchoringSource` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable, Hashable
  - not iOS, visionOS 2.0: `init(_:)`, `init(name:in:)`
  - iOS 18.0, not visionOS: `init(group:name:)`
  - iOS 27.0, visionOS 27.0: `init(referenceObject:)`

### `AnchoringComponent.ImageAnchoringSource` — struct (iOS 18.0, visionOS 2.0); conforms to Equatable, Hashable
  - iOS 18.0, visionOS 2.0: `init(_:physicalSize:)`, `init(group:name:)`

### `AnchoringComponent.AccessoryAnchoringSource` — struct (not iOS, visionOS 26.0); conforms to Equatable, Hashable
  - not iOS, visionOS 26.0: `locationName(named:)`, `accessoryLocations`
  - not iOS, visionOS 27.0: `init(type:location:)`

### `AnchoringComponent.AccessoryLocation` — struct (not iOS, visionOS 26.0); conforms to Equatable, Hashable
  - not iOS, visionOS 26.0: `static origin`, `name`

### `AnchoringComponent.AccessoryAnchoringSource.AccessoryType` — struct; conforms to Codable, Equatable, Hashable
  - not iOS, visionOS 27.0: `identifier`, `chirality`, `init(identifier:chirality:)`, `static leftController`, `static rightController`, `static eitherController`, `static stylus`

### `AnchoringComponent.Target.HandLocation.HandJoint` — struct (not iOS, visionOS 2.0); conforms to Hashable
  - not iOS, visionOS 2.0: `static wrist`, `static thumbTip`, `static indexFingerTip`, `static thumbKnuckle`, `static thumbIntermediateBase`, `static thumbIntermediateTip`, `static indexFingerMetacarpal`, `static indexFingerKnuckle`, `static indexFingerIntermediateBase`, `static indexFingerIntermediateTip`, `static middleFingerMetacarpal`, `static middleFingerKnuckle`, `static middleFingerIntermediateBase`, `static middleFingerIntermediateTip`, `static middleFingerTip`, `static ringFingerMetacarpal`, `static ringFingerKnuckle`, `static ringFingerIntermediateBase`, `static ringFingerIntermediateTip`, `static ringFingerTip`, `static littleFingerMetacarpal`, `static littleFingerKnuckle`, `static littleFingerIntermediateBase`, `static littleFingerIntermediateTip`, `static littleFingerTip`, `static forearmWrist`, `static forearmArm`

### `AnchoringComponent.PhysicsSimulation` — enum; conforms to Hashable
  - iOS 18.0, visionOS 2.0: `.none`, `.isolated`

### `HasPhysicsMotion` — protocol (iOS 13.0); conforms to Entity
  - iOS 13.0: `physicsMotion`

### `HasPhysics` — protocol (iOS 13.0); conforms to HasPhysicsBody, HasPhysicsMotion

### `NavigationMeshResource` — class; conforms to Resource, @unchecked Sendable
  - unannotated: `init(named:in:)`, `init(triangleIndices:vertices:offMeshConnections:configuration:)`, `init(mesh:offMeshConnections:configuration:)`, `markAreaInCylinder(position:radius:halfHeight:area:)`, `markFlagInCylinder(position:radius:halfHeight:flag:)`, `markAreaInBox(boundingBox:area:)`, `markFlagInBox(boundingBox:flag:)`, `layer`, `polygonIndices`, `vertices`, `areas`, `flags`, `offMeshConnections`, `configuration`, `heightData`, `removeAreaInCylinder(position:radius:halfHeight:area:)`, `removeFlagInCylinder(position:radius:halfHeight:flag:)`, `removeAreaInBox(boundingBox:area:)`, `removeFlagInBox(boundingBox:flag:)`, `markAreaOnPolygons(polygonIndices:area:)`, `markFlagOnPolygons(polygonIndices:flag:)`, `removeAreaOnPolygons(polygonIndices:area:)`, `removeFlagOnPolygons(polygonIndices:flag:)`, `markAreaOnOffMeshConnections(offMeshConnectionIndices:area:)`, `markFlagOnOffMeshConnections(offMeshConnectionIndices:flag:)`, `removeAreaOnOffMeshConnections(offMeshConnectionIndices:area:)`, `removeFlagOnOffMeshConnections(offMeshConnectionIndices:flag:)`, `init(polygonIndices:vertices:offMeshConnections:configuration:areas:flags:heightData:)`, `init(meshDescriptor:offMeshConnections:configuration:)`

### `NavigationMeshResource.OffMeshConnection` — struct
  - unannotated: `startPoint`, `endPoint`, `radius`, `isBidirectional`, `label`, `init(startPoint:endPoint:radius:isBidirectional:label:)`

### `NavigationMeshResource.PathNode` — struct; conforms to Sendable
  - unannotated: `position`, `category`, `label`, `init(position:category:label:)`

### `NavigationMeshResource.PathNode.Category` — enum; conforms to Sendable
  - unannotated: `.meshPoint`, `.offMeshConnection`
  - iOS 27.0, visionOS 27.0: conforms to Equatable, conforms to Hashable

### `NavigationMeshResource.Area` — struct; conforms to RawRepresentable, Hashable
  - unannotated: `rawValue`, `init(rawValue:)`, `init(_:)`

### `NavigationMeshResource.Flag` — struct; conforms to RawRepresentable, Hashable
  - unannotated: `rawValue`, `init(rawValue:)`, `init(_:)`

### `NavigationMeshResource.FlagGroup` — struct; conforms to OptionSet, Hashable
  - unannotated: `rawValue`, `init(rawValue:)`, `init(_:)`, `setFlag(_:)`, `unsetFlag(_:)`

### `NavigationMeshResource.Layer` — struct; conforms to RawRepresentable, Hashable
  - unannotated: `rawValue`, `init(rawValue:)`, `init(_:)`

### `NavigationMeshResource.Configuration` — struct
  - unannotated: `cellSize`, `cellHeight`, `walkableSlopeAngle`, `characterHeight`, `walkableClimb`, `characterRadius`, `maximumEdgeLength`, `maximumSimplificationError`, `minimumCellsPerRegion`, `minimumCellsToMergeRegions`, `detailSampleDistance`, `detailSampleMaximumError`, `maximumVerticesPerPolygon`, `partitionMethod`, `init(cellSize:cellHeight:walkableSlopeAngle:characterHeight:walkableClimb:characterRadius:)`

### `NavigationMeshResource.Configuration.PartitionMethod` — enum
  - unannotated: `.watershed`, `.monotone`, `.layer`
  - iOS 27.0, visionOS 27.0: conforms to Equatable, conforms to Hashable

### `NavigationMeshResource.HeightData` — struct
  - unannotated: `vertices`, `triangleIndices`, `polygonTriangleIndices`, `init(vertices:triangleIndices:polygonTriangleIndices:)`

### `CharacterControllerComponent` — struct (iOS 15.0); conforms to Component
  - iOS 15.0: `init()`, `init(radius:height:skinWidth:slopeLimit:stepLimit:upVector:collisionFilter:)`, `radius`, `height`, `skinWidth`, `slopeLimit`, `stepLimit`, `upVector`, `collisionFilter`, `static defaultRadius`, `static defaultHeight`, `static defaultSkinWidth`, `static defaultSlopeLimit`, `static defaultStepLimit`, `static defaultUpVector`

### `CharacterControllerComponent.Collision` — struct
  - iOS 15.0: `init(characterEntity:hitEntity:hitPosition:hitNormal:moveDirection:moveDistance:)`, `characterEntity`, `hitEntity`, `hitPosition`, `hitNormal`, `moveDirection`, `moveDistance`

### `CharacterControllerComponent.CollisionFlags` — struct; conforms to OptionSet
  - iOS 15.0: `init(rawValue:)`, `rawValue`, `static none`, `static side`, `static top`, `static bottom`

### `PostProcessEffect` — protocol (iOS 26.0, not visionOS); conforms to Sendable
  - iOS 26.0, not visionOS: `prepare(for:)`, `postProcess(context:)`

### `PostProcessEffectContext` — struct (iOS 26.0, not visionOS); conforms to ~Copyable
  - iOS 26.0, not visionOS: `device`, `commandBuffer`, `sourceColorTexture`, `sourceDepthTexture`, `targetColorTexture`, `projection`, `time`

### `HasBodyTracking` — protocol (iOS 13.0, not visionOS); conforms to HasTransform
  - iOS 13.0, not visionOS: `bodyTracking`

### `BodyTrackingComponent` — struct (iOS 13.0, not visionOS); conforms to Component, Equatable
  - iOS 13.0, not visionOS: `target`, `isPaused`, `init()`, `init(_:)`

### `BodyTrackingComponent.Target` — enum; conforms to Hashable
  - iOS 13.0, not visionOS: `.any`, `.body(...)`

### `SceneUpdateContext` — struct (iOS 15.0)
  - iOS 15.0: `scene`, `deltaTime`
  - not iOS, not visionOS: `entities(matching:when:)`
  - iOS 18.0, visionOS 1.0: `entities(matching:updatingSystemWhen:)`

### `System` — protocol (iOS 15.0)
  - iOS 15.0: `static dependencies`, `init(scene:)`, `update(context:)`, `static registerSystem()`

### `SystemUpdateCondition` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `static rendering`

### `UnlitMaterial.Program` — class; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `descriptor`, `init(descriptor:)`

### `UnlitMaterial.Program.Descriptor` — struct; conforms to Equatable, Hashable, Sendable
  - iOS 18.0, visionOS 2.0: `applyPostProcessToneMap`, `blendMode`, `init()`

### `Audio.Material` — struct; conforms to Hashable, Sendable
  - iOS 27.0, visionOS 27.0: `name`, `init(name:absorption:scattering:)`, `absorption(_:)`, `scattering(_:)`, `scalingAbsorption(by:)`, `scalingScattering(by:)`, `static default`, `static concrete`, `static wood`, `static glass`, `static metal`, `static dryWall`, `static plaster`, `static brick`, `static tile`, `static curtain`, `static parquet`, `static carpet`, `static seatingHard`, `static seatingUpholstered`, `static mattress`, `static marble`, `static soil`, `static sand`, `static water`, `static trees`, `static gravel`, `static ice`, `static snow`
  - not iOS, not visionOS: `scaleAbsorption(by:)`, `scaleScattering(by:)`, `absorption(scaledBy:)`, `scattering(scaledBy:)`
- extension of `Cancellable`
  - iOS 15.0: `storeWhileEntityActive(_:)`

### `BlendShapeWeightsData` — struct (iOS 18.0, visionOS 2.0); conforms to Identifiable
  - iOS 18.0, visionOS 2.0: `init(id:weights:)`, `id`, `weights`, `weightNames`

### `BlendShapeWeightsSet` — struct (iOS 18.0, visionOS 2.0)
  - iOS 18.0, visionOS 2.0: `init()`, `default`, `count`, `isEmpty`, `subscript(blendShapeName:)`, `contains(_:)`, `set(_:)`, conforms to Sequence, `makeIterator()`, conforms to Collection, `startIndex`, `endIndex`, `index(of:)`, `subscript(index:)`, `index(after:)`

### `BlendShapeWeightsSet.Iterator` — struct; conforms to IteratorProtocol
  - iOS 18.0, visionOS 2.0: `next()`

### `BlendShapeWeightsComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `init(weightsMapping:)`, `weightSet`

### `SpinAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `revolutions`, `localAxis`, `timingFunction`, `isAdditive`, `animatedValueType`, `init(revolutions:localAxis:timingFunction:isAdditive:)`

### `PixelCastHit` — struct (iOS 18.0, not visionOS); conforms to Equatable, Sendable
  - iOS 18.0, not visionOS: `entity`, `normal`, `position`, `meshPart`, `instance`, `primitive`, `barycentric`

### `ModelDebugOptionsComponent` — struct (iOS 14.0); conforms to Component
  - iOS 14.0: `visualizationMode`, `init(visualizationMode:)`

### `ModelDebugOptionsComponent.VisualizationMode` — enum; conforms to String
  - iOS 14.0: `.none`, `.normal`, `.tangent`, `.bitangent`, `.baseColor`, `.baseColorTexture`, `.textureCoordinates`, `.finalColor`, `.finalAlpha`, `.roughness`, `.metallic`, `.ambientOcclusion`, `.specular`, `.emissive`, `.clearcoat`, `.clearcoatRoughness`, `.lightingDiffuse`, `.lightingSpecular`, `init(rawValue:)`, `rawValue`, conforms to Equatable, conforms to Hashable, conforms to RawRepresentable
  - iOS 18.0, visionOS 2.0: `.clearcoatNormal`

### `PlayAudioAction` — struct (iOS 18.0, visionOS 2.0); conforms to EntityAction, Codable
  - iOS 18.0, visionOS 2.0: `targetEntity`, `audioResourceName`, `gain`, `useControlledPlayback`, `animatedValueType`, `init(targetEntity:audioResourceName:gain:useControlledPlayback:)`

### `HasHierarchy` — protocol (iOS 13.0); conforms to Entity
  - iOS 13.0: `parent`, `setParent(_:preservingWorldTransform:)`, `children`, `addChild(_:preservingWorldTransform:)`, `removeChild(_:preservingWorldTransform:)`, `removeFromParent(preservingWorldTransform:)`

### `PortalCrossingComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component
  - iOS 18.0, visionOS 2.0: `init()`

### `PhysicsJointsComponent` — struct (iOS 18.0, visionOS 2.0); conforms to Component, Equatable
  - iOS 18.0, visionOS 2.0: `init()`, `joints`

### `RotationOrder` — extension
  - iOS 13.0: conforms to Equatable, conforms to Hashable, conforms to RawRepresentable

## Module `RealityKit`


### `ParticleEmitterComponent.Presets` — struct
  - iOS 18.0, visionOS 1.0: `static fireworks`, `static impact`, `static magic`, `static rain`, `static snow`, `static sparks`

### `ParticleEmitterComponent.ParticleEmitter` — extension
  - iOS 18.0, visionOS 1.0: `color`

### `ParticleEmitterComponent.ParticleEmitter.ParticleColor` — enum; conforms to Equatable
  - iOS 18.0, visionOS 1.0: `.constant(...)`, `.evolving(...)`

### `ParticleEmitterComponent.ParticleEmitter.ParticleColor.ColorValue` — enum; conforms to Equatable
  - iOS 18.0, visionOS 1.0: `.single(...)`, `.random(...)`

### `ParticleEmitterComponent` — extension
  - iOS 18.0, visionOS 1.0: `timing`

### `ParticleEmitterComponent.Timing` — enum; conforms to Equatable, Codable
  - iOS 18.0, visionOS 1.0: `.once(...)`, `.repeating(...)`

### `ParticleEmitterComponent.Timing.VariableDuration` — struct; conforms to Equatable, Codable
  - iOS 18.0, visionOS 1.0: `duration`, `variation`, `init(duration:variation:)`

### `ARKitAnchorComponent` — struct (iOS 26.0, visionOS 26.0); conforms to TransientComponent
  - not visionOS: `arAnchor`

### `AnchorEntity` — extension
  - not visionOS: `init(anchor:)`, `init(raycastResult:)`

### `AnchoringComponent.AccessoryAnchoringSource` — extension
  - not iOS, visionOS 26.0: `init(device:)`

### `AnchoringComponent` — extension
  - not visionOS: `init(_:)`

### `ShapeResource` — extension
  - iOS 18.0: `static generateStaticMesh(from:)`

### `ARView` — class (not visionOS); conforms to ARViewBase
  - not visionOS: `scene`, `debugOptions`, `environment`, `cameraTransform`, `audioListener`, `init(coder:)`, `init(frame:)`, `init(frame:cameraMode:automaticallyConfigureSession:)`, `snapshot(saveToHDR:completion:)`, `didMoveToWindow()`
  - not visionOS, deprecated: `init(frame:cameraMode:)`
  - iOS 13.0: conforms to ARSessionProviding
  - iOS 13.0, not visionOS: `session`, `cameraMode`, `automaticallyConfigureSession`, conforms to UIGestureRecognizerDelegate, `installGestures(_:for:)`, `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`, `gestureRecognizer(_:shouldReceive:)`, `static layerClass`, `contentScaleFactor`, `didMoveToSuperview()`, `layoutSubviews()`, `touchesBegan(_:with:)`, `touchesMoved(_:with:)`, `touchesEnded(_:with:)`, `touchesCancelled(_:with:)`, `physicsOrigin`, `project(_:)`, `unproject(_:viewport:)`, `unproject(_:ontoPlane:)`, `ray(through:)`, `hitTest(_:query:mask:)`, `entity(at:)`, `entities(at:)`, `hitTest(_:types:)`, `makeRaycastQuery(from:allowing:alignment:)`, `trackedRaycast(from:allowing:alignment:updateHandler:)`, `raycast(from:allowing:alignment:)`, `renderOptions`
  - iOS 14.0: `unproject(_:ontoPlane:relativeToCamera:)`
  - iOS 15.0: `renderCallbacks`

### `ARView.DebugOptions` — struct; conforms to OptionSet
  - not visionOS: `rawValue`, `static none`, `static showPhysics`, `static showStatistics`, `static showWorldOrigin`, `static showAnchorOrigins`, `static showAnchorGeometry`, `static showFeaturePoints`, `init(rawValue:)`
  - iOS 13.4: `static showSceneUnderstanding`

### `ARView.CameraMode` — enum
  - iOS 13.0, not visionOS: `.ar`, `.nonAR`, conforms to Equatable, conforms to Hashable

### `ARView.Environment` — struct
  - iOS 13.0, not visionOS: `background`, `lighting`, `reverb`, `init(background:lighting:reverb:)`
  - iOS 13.4: `sceneUnderstanding`

### `ARView.Environment.Background` — struct
  - iOS 13.0, not visionOS: `static cameraFeed(exposureCompensation:)`, `static skybox(_:)`, `static color(_:)`

### `ARView.Environment.ImageBasedLight` — struct
  - iOS 13.0, not visionOS: `resource`, `intensityExponent`

### `ARView.Environment.Reverb` — enum
  - iOS 13.0, not visionOS: `.noReverb`, `.preset(...)`, `static automatic`
  - iOS 15.0, not visionOS: conforms to Equatable, Hashable

### `ARView.Environment.Reverb.Preset` — enum
  - iOS 13.0, not visionOS: `.smallRoom`, `.mediumRoom`, `.largeRoom`, `.mediumHall`, `.largeHall`, `.cathedral`, conforms to Equatable, conforms to Hashable
  - iOS 16.0, not visionOS: conforms to CaseIterable, `static allCases`

### `ARView.Environment.SceneUnderstanding` — struct (iOS 13.4)
  - iOS 13.4: `options`

### `ARView.Environment.SceneUnderstanding.Options` — struct; conforms to OptionSet
  - iOS 13.4: `rawValue`, `static occlusion`, `static receivesLighting`, `static collision`, `static physics`, `static default`, `init(rawValue:)`

### `ARView.EntityGestures` — struct; conforms to OptionSet
  - iOS 13.0, not visionOS: `rawValue`, `init(rawValue:)`, `static translation`, `static rotation`, `static scale`, `static all`

### `ARView.PostProcessContext` — struct (iOS 15.0)
  - iOS 15.0: `init(_:_:_:_:_:_:_:)`, `device`, `commandBuffer`, `sourceColorTexture`, `sourceDepthTexture`, `targetColorTexture`, `projection`, `time`

### `ARView.RenderCallbacks` — struct (iOS 15.0)
  - iOS 15.0: `prepareWithDevice`, `postProcess`, `init()`

### `ARView.RenderOptions` — struct; conforms to OptionSet
  - iOS 13.0, not visionOS: `static disableCameraGrain`, `static disableGroundingShadows`, `static disableMotionBlur`, `static disableDepthOfField`, `static disableHDR`, `static disablePersonOcclusion`, `static disableAREnvironmentLighting`, `static disableFaceMesh`, `rawValue`, `init(rawValue:)`
  - not visionOS, deprecated: `static disableAutomaticLighting`, `static disableFaceOcclusions`

### `Entity.ConfigurationCatalog` — extension

### `DirectionalLightComponent` — extension
  - iOS 13.0, visionOS 2.0: `color`
  - not iOS, visionOS 2.0: `init(color:intensity:)`
  - not visionOS: `init(color:intensity:isRealWorldProxy:)`

### `AccessibilityEvents` — enum (iOS 17.0)

### `AccessibilityEvents.RotorNavigation` — struct (iOS 17.0); conforms to Event
  - iOS 17.0: `rotorType`, `hostEntity`, `currentItem`, `searchDirection`, `resultHandler`, `init(rotorType:hostEntity:currentItem:searchDirection:resultHandler:)`

### `AccessibilityEvents.Activate` — struct; conforms to Event
  - iOS 17.0: `entity`, `init(entity:)`

### `AccessibilityEvents.Increment` — struct; conforms to Event
  - iOS 17.0: `entity`, `init(entity:)`

### `AccessibilityEvents.Decrement` — struct; conforms to Event
  - iOS 17.0: `entity`, `init(entity:)`

### `AccessibilityEvents.CustomAction` — struct; conforms to Event
  - iOS 17.0: `key`, `entity`, `init(key:entity:)`

### `AccessibilityComponent` — extension
  - iOS 17.0: `traits`, `customRotors`

### `AccessibilityComponent.RotorType` — enum (iOS 17.0); conforms to Equatable
  - iOS 17.0: `.system(...)`, `.custom(...)`

### `Entity` — extension
  - iOS 17.0: `accessibilityLabelKey`, `accessibilityValue`, `accessibilityTraits`, `accessibilityCustomContent`, `accessibilityCustomRotors`, `accessibilitySystemActions`, `accessibilityCustomActions`

### `EntityGestureRecognizer` — protocol (iOS 13.0, not visionOS); conforms to UIGestureRecognizer
  - iOS 13.0, not visionOS: `entity`, `location(in:)`

### `EntityRotationGestureRecognizer` — class (not visionOS); conforms to UIRotationGestureRecognizer, EntityGestureRecognizer
  - not visionOS: `entity`, `touchesBegan(_:with:)`, `canPrevent(_:)`, `init(target:action:)`

### `EntityScaleGestureRecognizer` — class (not visionOS); conforms to UIPinchGestureRecognizer, EntityGestureRecognizer
  - not visionOS: `entity`, `touchesBegan(_:with:)`, `canPrevent(_:)`, `init(target:action:)`

### `EntityTranslationGestureRecognizer` — class (not visionOS); conforms to UIGestureRecognizer, EntityGestureRecognizer
  - not visionOS: `entity`, `touchesBegan(_:with:)`, `touchesEnded(_:with:)`, `touchesMoved(_:with:)`, `touchesCancelled(_:with:)`, `reset()`, `canPrevent(_:)`, `translation(in:)`, `setTranslation(_:in:)`, `velocity(in:)`, `location(in:)`, `init(target:action:)`

### `HoverEffectComponent.SpotlightHoverEffectStyle` — extension
  - iOS 18.0, visionOS 2.0: `color`, `init(color:strength:opacityFunction:)`, `init(color:strength:)`

### `HoverEffectComponent.HighlightHoverEffectStyle` — extension
  - iOS 18.0, visionOS 2.0: `color`, `init(color:strength:opacityFunction:)`, `init(color:strength:)`

### `Material` — extension

### `SimpleMaterial` — extension
  - deprecated: `tintColor`, `baseColor`
  - iOS 13.0: `init(color:roughness:isMetallic:)`

### `UnlitMaterial` — extension
  - deprecated: `tintColor`, `baseColor`
  - iOS 13.0: `init(color:)`
  - iOS 18.0, visionOS 1.0: `init(color:applyPostProcessToneMap:)`

### `MaterialParameters.Value` — extension
  - iOS 18.0, visionOS 1.0: `colorValue`, `static color(_:)`

### `PhysicallyBasedMaterial.BaseColor` — extension
  - iOS 15.0: `init(tint:texture:)`, `tint`

### `PhysicallyBasedMaterial.EmissiveColor` — extension
  - iOS 15.0: `init(color:texture:)`, `color`

### `PhysicallyBasedMaterial.SheenColor` — extension
  - iOS 15.0: `init(tint:texture:)`, `tint`

### `CustomMaterial.BaseColor` — extension
  - iOS 15.0, not visionOS: `init(tint:texture:)`, `tint`

### `CustomMaterial.EmissiveColor` — extension
  - iOS 15.0, not visionOS: `init(color:texture:)`, `color`

### `MaterialColorParameter` — enum (iOS 13.0); conforms to Hashable
  - iOS 13.0: `.color(...)`, `.texture(...)`, `init(_colorLiteralRed:green:blue:alpha:)`

### `MeshResource` — extension
  - iOS 13.0: `static generateText(_:extrusionDepth:font:containerFrame:alignment:lineBreakMode:)`
- extension of `MCPeerID`
  - iOS 13.0: conforms to SynchronizationPeerID

### `MultipeerConnectivityService` — class (iOS 13.0, not visionOS); conforms to SynchronizationService
  - iOS 13.0, not visionOS: `session`, `init(session:)`, `setHandshake(count:timeoutMs:)`, `entity(for:)`, `owner(of:)`, `giveOwnership(of:toPeer:)`, `startSync()`, `stopSync()`

### `PointLightComponent` — extension
  - iOS 13.0, visionOS 2.0: `color`, `init(color:intensity:attenuationRadius:)`
  - iOS 18.0, visionOS 2.0: `init(color:intensity:attenuationRadius:attenuationFalloffExponent:)`

### `SpotLightComponent` — extension
  - iOS 13.0, visionOS 2.0: `color`, `init(color:intensity:innerAngleInDegrees:outerAngleInDegrees:attenuationRadius:)`
  - iOS 18.0, visionOS 2.0: `init(color:intensity:innerAngleInDegrees:outerAngleInDegrees:attenuationRadius:attenuationFalloffExponent:)`

### `TextComponent` — extension
  - iOS 18.0, visionOS 1.0: `edgeInsets`

### `TextureResource` — extension
  - iOS 13.0: `static load(named:in:)`
  - deprecated: `static loadAsync(named:in:)`, `static loadAsync(named:in:options:)`
  - iOS 15.0: `static load(named:in:options:)`
  - iOS 18.0, visionOS 1.0: `init(named:in:)`, `init(named:in:options:)`

## Module `_RealityKit_SwiftUI (cross-import overlay of RealityKit + SwiftUI)`


### `RealityViewLayoutOption` — struct (iOS 26.0, visionOS 26.0); conforms to Equatable
  - iOS 26.0, visionOS 26.0: `static flexible`, `static centered`, `static fixedSize`
- extension of `View`
  - iOS 26.0, visionOS 26.0: `realityViewLayoutBehavior(_:)`
  - iOS 18.0, not visionOS: `realityViewCameraControls(_:)`

### `MeshResource.ShapeExtrusionOptions` — extension
  - iOS 18.0, visionOS 2.0: `chamferProfile`

### `MeshResource` — extension
  - iOS 18.0, visionOS 2.0: `init(extruding:extrusionOptions:)`

### `ObjectCaptureView` — struct (iOS 17.0, not visionOS); conforms to View where Overlay : View
  - iOS 17.0, not visionOS: `init(session:)`, `init(session:cameraFeedOverlay:)`, `body`, conforms to Sendable
  - iOS 18.0, not visionOS: `hideObjectReticle(_:)`

### `ObjectCaptureSession` — class (iOS 17.0, not visionOS); conforms to Identifiable
  - iOS 17.0, not visionOS: `static isSupported`, `init()`, `state`, `stateUpdates`, `feedback`, `feedbackUpdates`, `cameraTracking`, `cameraTrackingUpdates`, `isPaused`, `isPausedUpdates`, `userCompletedScanPass`, `userCompletedScanPassUpdates`, `canRequestImageCapture`, `canRequestImageCaptureUpdates`, `numberOfShotsTaken`, `numberOfShotsTakenUpdates`, `maximumNumberOfInputImages`, `configuration`, `start(imagesDirectory:configuration:)`, `resume()`, `pause()`, `startDetecting()`, `resetDetection()`, `startCapturing()`, `beginNewScanPassAfterFlip()`, `beginNewScanPass()`, `finish()`, `cancel()`, `requestImageCapture()`, conforms to nonisolated Observable, conforms to Sendable
  - iOS 18.0, not visionOS: `shouldPlayHaptics`, `isAutoCaptureEnabled`

### `ObjectCaptureSession.Updates` — struct; conforms to AsyncSequence, Sendable where Element : Sendable
  - iOS 17.0, not visionOS: `makeAsyncIterator()`

### `ObjectCaptureSession.Updates.Iterator` — struct; conforms to AsyncIteratorProtocol
  - iOS 17.0, not visionOS: `next()`

### `ObjectCaptureSession.Error` — enum; conforms to Error, LocalizedError
  - iOS 17.0, not visionOS: `.directoryNotEmpty(...)`, `.insufficientStorage(...)`, `.cancelled`, `.sensorFailed`, `.trackingFailed`, `localizedDescription`

### `ObjectCaptureSession.CaptureState` — enum; conforms to Equatable
  - iOS 17.0, not visionOS: `.initializing`, `.ready`, `.detecting`, `.capturing`, `.finishing`, `.completed`, `.failed(...)`
  - not visionOS: conforms to Sendable

### `ObjectCaptureSession.Feedback` — enum; conforms to Equatable
  - iOS 17.0, not visionOS: `.objectTooClose`, `.objectTooFar`, `.movingTooFast`, `.environmentLowLight`, `.environmentTooDark`, `.outOfFieldOfView`, `.objectNotFlippable`, `.overCapturing`, conforms to Hashable
  - iOS 17.4, not visionOS: `.objectNotDetected`
  - not visionOS: conforms to Sendable

### `ObjectCaptureSession.Tracking` — enum; conforms to Equatable
  - iOS 17.0, not visionOS: `.notAvailable`, `.limited(...)`, `.normal`

### `ObjectCaptureSession.Tracking.Reason` — enum
  - iOS 17.0, not visionOS: `.initializing`, `.relocalizing`, `.excessiveMotion`, `.insufficientFeatures`, conforms to Equatable, conforms to Hashable

### `ObjectCaptureSession.Configuration` — struct
  - iOS 17.0, not visionOS: `init()`, `checkpointDirectory`, `isOverCaptureEnabled`

### `RealityCoordinateSpaceProjecting` — protocol (iOS 18.0, not visionOS)
  - iOS 18.0, not visionOS: `project(point:to:)`, `unproject(_:from:to:ontoPlane:)`, `ray(through:in:to:)`, `entity(at:in:)`, `entities(at:in:)`, `hitTest(point:in:query:mask:)`

### `RealityViewCameraContent` — struct (iOS 18.0, not visionOS); conforms to RealityViewContentProtocol
  - iOS 18.0, not visionOS: conforms to RealityCoordinateSpaceProjecting, `project(point:to:)`, `unproject(_:from:to:ontoPlane:)`, `ray(through:in:to:)`, `entity(at:in:)`, `entities(at:in:)`, `hitTest(point:in:query:mask:)`, `entities`, `subscribe(to:on:componentType:_:)`
  - not visionOS: `camera`, `cameraTarget`, `environment`, `audioListener`, `renderingEffects`
  - iOS 26.0, not visionOS: `animate(body:completion:)`

### `EntityTargetValue` — struct (iOS 18.0, visionOS 1.0)
  - iOS 18.0, not visionOS: conforms to RealityCoordinateSpaceProjecting, `project(point:to:)`, `unproject(_:from:to:ontoPlane:)`, `ray(through:in:to:)`, `entity(at:in:)`, `entities(at:in:)`, `hitTest(point:in:query:mask:)`, `unproject(_:to:)`, `unproject(_:from:to:)`
  - iOS 18.0, visionOS 1.0: `gestureValue`, `entity`, `subscript(dynamicMember:)`, conforms to Equatable where Value : Equatable

### `ObjectCapturePointCloudView` — struct (iOS 17.0, not visionOS); conforms to View
  - iOS 17.0, not visionOS: `init(session:)`, `body`, conforms to Sendable
  - iOS 18.0, not visionOS: `showShotLocations(_:)`

### `ResolvedModel3D` — struct (not iOS, visionOS 1.0); conforms to View
  - not iOS, visionOS 1.0: `body`, `resizable(_:)`, conforms to Sendable

### `RealityView` — struct (iOS 18.0, visionOS 1.0); conforms to View where Content : View
  - iOS 18.0, visionOS 1.0: `body`, conforms to Sendable
  - iOS 18.0, not visionOS: `init(make:update:placeholder:)`, `init(make:update:)`

### `RealityViewDefaultPlaceholder` — struct (iOS 18.0, visionOS 1.0); conforms to View
  - iOS 18.0, visionOS 1.0: `body`, conforms to Sendable

### `RealityViewContentProtocol` — protocol (iOS 18.0, visionOS 1.0)
  - iOS 18.0, visionOS 1.0: `assoc Entities`, `entities`, `subscribe(to:on:componentType:_:)`, `subscribe(to:on:_:)`, `subscribe(to:componentType:_:)`, `add(_:)`, `remove(_:)`

### `RealityViewEntityCollection` — struct (iOS 18.0, visionOS 1.0); conforms to EntityCollection
  - iOS 18.0, visionOS 1.0: `startIndex`, `endIndex`, `count`, `subscript(index:)`, `index(after:)`, `insert(contentsOf:beforeIndex:)`, `append(contentsOf:)`, `remove(_:)`, `remove(at:)`, `removeAll()`, `replaceAll(_:)`

### `Model3DAsset` — class (not iOS, visionOS 26.0)
  - not iOS, visionOS 26.0: `animationPlaybackController`, `availableAnimations`, `selectedAnimation`, `init(named:in:)`, `init(url:)`, conforms to nonisolated Observable

### `Model3DAsset.EntityAnimation` — struct; conforms to Identifiable, Hashable
  - not iOS, visionOS 26.0: `id`, `path`

### `Entity` — extension
  - iOS 26.0, visionOS 26.0: `static animate(_:body:completion:)`
- extension of `Binding`
  - iOS 26.0, visionOS 26.0: `subscript(componentType:)`

### `RealityViewCameraContent.Body` — struct; conforms to View where Placeholder : View
  - iOS 18.0, not visionOS: `body`, conforms to Sendable
- extension of `EnvironmentValues`
  - iOS 18.0, not visionOS: `realityViewCameraControls`

### `RealityViewCamera` — struct (iOS 18.0, not visionOS); conforms to Sendable
  - iOS 18.0, not visionOS: `static virtual`, `static spatialTracking`

### `RealityViewEnvironment` — struct (iOS 18.0, not visionOS); conforms to Sendable
  - iOS 18.0, not visionOS: `static default`, `static skybox(_:)`

### `RealityViewRenderingEffects` — struct (iOS 18.0, not visionOS); conforms to Sendable
  - iOS 18.0, not visionOS: `motionBlur`, `depthOfField`, `cameraGrain`, `antialiasing`, `dynamicRange`
  - iOS 26.0, not visionOS: `customPostProcessing`

### `RealityViewPostProcessEffect` — struct (iOS 26.0, not visionOS); conforms to Sendable
  - iOS 26.0, not visionOS: `static none`, `static effect(_:)`

### `RealityViewRenderingEffectMode` — struct (iOS 18.0, not visionOS); conforms to Hashable, Sendable
  - iOS 18.0, not visionOS: `static default`, `static enabled`, `static disabled`

### `RealityViewDynamicRange` — struct (iOS 18.0, not visionOS); conforms to Hashable, Sendable
  - iOS 18.0, not visionOS: `static default`, `static standard`

### `Model3DPhase` — enum (not iOS, visionOS 1.0)
  - not iOS, visionOS 1.0: `.empty`, `.success(...)`, `.failure(...)`, `model`, `error`

### `Model3D` — struct (not iOS, visionOS 1.0); conforms to View, where Content : View
  - not iOS, visionOS 1.0: `init(url:)`, `init(url:content:placeholder:)`, `init(url:transaction:content:)`, `init(named:bundle:)`, `init(named:bundle:content:placeholder:)`, `init(named:bundle:transaction:content:)`, `body`
  - not iOS, visionOS 26.0: `init(from:configurations:)`, `init(from:configurations:content:placeholder:)`, `init(from:configurations:transaction:content:)`, `init(asset:content:)`, `init(asset:)`

### `Model3DPlaceholderContent` — struct (not iOS, visionOS 1.0); conforms to View where Model : View, Placeholder : View
  - not iOS, visionOS 1.0: `body`, conforms to Sendable

### `GestureComponent` — extension
  - iOS 26.0, visionOS 26.0: `init(_:)`
- extension of `Gesture`
  - iOS 18.0, visionOS 1.0: `targetedToAnyEntity()`, `targetedToEntity(_:)`, `targetedToEntity(where:)`

## Module `_RealityKit_ComputeGraph (cross-import overlay)`


### `ComputeGraphComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `init()`, `init(resource:)`, `resource`, `pipelines`, `state`, `models`, `materials`, `randomSeed`, `setTexture(_:port:)`, `setTexture(_:at:)`, `setBuffer(_:bufferOffset:elementCount:at:)`, `setOutputEnabled(_:enabled:)`, `isOutputEnabled(_:)`, `simulationRate`, `play()`, `pause()`, `step()`, `fastForward()`, `fastForward(stepCount:stepDeltaTime:)`, `spawn(element:in:)`, `spawn(elements:in:)`, `uniformHandle(named:)`, `replaceUniforms(_:)`, `setUniformData(_:for:)`, `setUniformValue(_:for:)`, `setUniformValue(_:named:)`, `findBufferIndex(port:)`, `firstBufferIndex(type:)`

### `ComputeGraphComponent.UniformHandle` — struct (iOS 27.0, visionOS 27.0)

### `ComputeGraphComponent.SimulationState` — enum (iOS 27.0, visionOS 27.0)
  - iOS 27.0, visionOS 27.0: `.playing`, `.paused`, `.stepping`, conforms to Equatable, conforms to Hashable

### `ComputeGraphOutputComponent` — struct (iOS 27.0, visionOS 27.0); conforms to TransientComponent
  - iOS 27.0, visionOS 27.0: `outputID`

### `ComputeGraphRuntimeComponent` — struct (iOS 27.0, visionOS 27.0); conforms to TransientComponent
  - iOS 27.0, visionOS 27.0: `simulation`, `readOutput(_:)`, `readOutputs(_:)`

### `ComputeGraphSharedUniforms` — class (iOS 27.0, visionOS 27.0); conforms to TransientComponent
  - iOS 27.0, visionOS 27.0: `init()`, `setUniform(_:)`, `uniform(_:)`, `setUniformTransform(_:)`, `setUniformTransform(type:transform:)`

### `ComputeGraphViewpointComponent` — struct (iOS 27.0, visionOS 27.0); conforms to TransientComponent
  - iOS 27.0, visionOS 27.0: `viewDirection`, `viewPosition`, `init()`

### `ComputeGraphResource` — class; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `init(contentsOf:)`, `init(contentsOf:bundle:)`, `init(graph:pipelines:dependencies:)`

### `ComputeGraphResource.BufferInfo` — struct (iOS 27.0, visionOS 27.0)
  - iOS 27.0, visionOS 27.0: `init(buffer:bufferOffset:elementCount:)`

### `ComputeGraphResource.Dependencies` — struct (iOS 27.0, visionOS 27.0)
  - iOS 27.0, visionOS 27.0: `init()`, `outputMaterials`, `outputModels`, `textures`, `buffers`

## Module `_USDKit_RealityKit (cross-import overlay)`


### `USDStageComponent` — struct (iOS 27.0, visionOS 27.0); conforms to Component
  - iOS 27.0, visionOS 27.0: `allowsHitTesting`, `rendersAutomatically`, `stage`, `timeCode`, `init(allowsHitTesting:)`, `init(_:timeCode:allowsHitTesting:)`, `static waitForRenderCompletion(on:)`, conforms to Equatable, conforms to Codable
  - not iOS, visionOS 27.0: `static coordinateSpace(on:at:timeCode:)`

### `USDStageComponent.RenderResult` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `status`, `errors`

### `USDStageComponent.RenderResult.Status` — enum; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `.completed`, `.failed`, conforms to Equatable, conforms to Hashable

### `USDPlayer` — class
  - unannotated: `init(stage:)`, `init(stage:gpuFamily:)`, `update(timeCode:)`, `importCustomIBLTexture(data:)`

### `USDPlayer.FrameUpdate` — struct; conforms to ~Copyable
  - unannotated: `timeCode`, `meshAdditions`, `materialAdditions`, `textureAdditions`, `deformationAdditions`, `meshUpdates`, `materialUpdates`, `deformationUpdates`, `meshRemovals`, `materialRemovals`, `textureRemovals`, `deformationRemovals`, `errors`, `takeMeshAddition(id:)`, `takeMeshUpdate(id:)`, `takeMaterialAddition(id:)`, `takeMaterialUpdate(id:)`, `takeTextureAddition(id:)`, `takeDeformationAddition(id:)`, `takeDeformationUpdate(id:)`

### `USDPlayer.DeformationData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `skinning`, `blendShapes`, `renormalization`

### `USDPlayer.DeformationData.SkinningData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `influencePerVertexCount`, `jointTransforms`, `inverseBindPoses`, `influenceJointIndices`, `influenceWeights`, `geometryBindTransform`

### `USDPlayer.DeformationData.SkinningData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `jointTransforms`, `inverseBindPoses`, `influenceJointIndices`, `influenceWeights`, `geometryBindTransform`

### `USDPlayer.DeformationData.BlendShapeData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `weights`, `positionOffsets`

### `USDPlayer.DeformationData.BlendShapeData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `weights`, `positionOffsets`

### `USDPlayer.DeformationData.RenormalizationData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `vertexIndicesPerTriangle`, `vertexAdjacencies`, `vertexAdjacencyEndIndices`

### `USDPlayer.DeformationData.RenormalizationData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `vertexIndicesPerTriangle`, `vertexAdjacencies`, `vertexAdjacencyEndIndices`

### `USDPlayer.DeformationData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `skinning`, `blendShapes`, `renormalization`

### `USDPlayer.MeshID` — struct
  - iOS 27.0, visionOS 27.0: `description`, conforms to CustomStringConvertible, conforms to Sendable, conforms to Hashable

### `USDPlayer.MaterialID` — struct
  - iOS 27.0, visionOS 27.0: `description`, conforms to CustomStringConvertible, conforms to Sendable, conforms to Hashable

### `USDPlayer.TextureID` — struct
  - iOS 27.0, visionOS 27.0: `description`, conforms to CustomStringConvertible, conforms to Sendable, conforms to Hashable

### `USDPlayer.DeformationID` — struct
  - iOS 27.0, visionOS 27.0: `description`, conforms to CustomStringConvertible, conforms to Sendable, conforms to Hashable

### `USDPlayer.MeshData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `primPath`, `descriptor`, `parts`, `indexData`, `vertexData`, `instanceTransforms`, `assignedMaterials`, `meshType`

### `USDPlayer.MeshData.MeshType` — enum; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `.rigid`, `.deformable(...)`

### `USDPlayer.MeshData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `parts`, `indexData`, `vertexData`, `instanceTransforms`, `assignedMaterials`, `meshType`

### `USDPlayer.MaterialData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `primPath`, `assignedTextures`, `shaderGraph`

### `USDPlayer.MaterialData.Update` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `assignedTextures`

### `USDPlayer.TextureLevelInfo` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `dataOffset`, `byteCountPerRow`, `byteCountPerImage`

### `USDPlayer.TextureData` — struct; conforms to Sendable
  - iOS 27.0, visionOS 27.0: `id`, `assetPath`, `descriptor`, `layout`, `data`

### `USDRenderError` — struct (iOS 27.0, visionOS 27.0); conforms to LocalizedError, Sendable
  - iOS 27.0, visionOS 27.0: `errorDescription`
