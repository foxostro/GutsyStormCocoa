//
//  GSTerrain.h
//  GutsyStorm
//
//  Created by Andrew Fox on 10/28/12.
//  Copyright © 2012-2016 Andrew Fox. All rights reserved.
//

@class GSCamera;
@class GSChunkStore;
@class GSTerrainCursor;
@class GSTextureArray;

@interface GSTerrain : NSObject

- (nonnull instancetype)initWithSeed:(NSUInteger)seed
                               camera:(nonnull GSCamera *)camera
                            glContext:(nonnull NSOpenGLContext *)glContext;

/* Assumes the caller has already locked the GL context or
 * otherwise ensures no concurrent GL calls will be made.
 */
- (void)draw;

- (void)updateWithDeltaTime:(float)dt cameraModifiedFlags:(unsigned)cameraModifiedFlags;

- (void)placeBlockUnderCrosshairs;

- (void)removeBlockUnderCrosshairs;

- (void)testPurge;

- (void)printInfo;

/* Clean-up in preparation for destroying the terrain object.
 * For example, synchronize with the disk one last time and resources.
 */
- (void)shutdown;

@end
