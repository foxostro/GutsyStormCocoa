//
//  GSFace.m
//  GutsyStorm
//
//  Created by Andrew Fox on 1/12/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import "GSTerrainBuffer.h" // for GSTerrainBufferElement, needed by GSVoxel.h
#import "GSVoxel.h" // for GSVoxelFace, needed by GSFace.h
#import "GSFace.h"
#import "GSBoxedTerrainVertex.h"

@implementation GSFace

+ (NSArray<GSBoxedTerrainVertex *> *)decomposeQuad:(NSArray<GSBoxedTerrainVertex *> *)verticesIn
{
    NSParameterAssert(verticesIn);
    
    NSArray<GSBoxedTerrainVertex *> *verticesOut = nil;
    NSUInteger count = verticesIn.count;
    
    assert(count == 4 || count == 3);
    
    if (count == 3) {
        verticesOut = verticesIn;
    } else {
        verticesOut = @[ verticesIn[0], verticesIn[1], verticesIn[2],
                         verticesIn[0], verticesIn[2], verticesIn[3] ];
    }
    
    return verticesOut;
}

+ (BOOL)determineEligibilityForOmission:(NSArray<GSBoxedTerrainVertex *> *)vertices
{
    NSParameterAssert(vertices && vertices.count >= 3);

    // The face is eligible for omission if it fits exactly into a cube face. (i.e. unit area)
    vector_float3 a = [((GSBoxedTerrainVertex *)[vertices objectAtIndex:0]) position];
    vector_float3 b = [((GSBoxedTerrainVertex *)[vertices objectAtIndex:1]) position];
    vector_float3 c = [((GSBoxedTerrainVertex *)[vertices objectAtIndex:2]) position];

    vector_float3 ba = b - a;
    vector_float3 bc = b - c;
    vector_float3 n1 = vector_cross(ba, bc);

    BOOL result = vector_equal(n1, vector_make(0, 0, -1)) ||
                  vector_equal(n1, vector_make(0, 0, +1)) ||
                  vector_equal(n1, vector_make(0, -1, 0)) ||
                  vector_equal(n1, vector_make(0, +1, 0)) ||
                  vector_equal(n1, vector_make(-1, 0, 0)) ||
                  vector_equal(n1, vector_make(+1, 0, 0));
    
    return result;
}

+ (GSFace *)faceWithQuad:(NSArray<GSBoxedTerrainVertex *> *)vertices correspondingCubeFace:(GSVoxelFace)face
{
    NSParameterAssert(vertices && vertices.count == 4);
    NSArray<GSBoxedTerrainVertex *> *triangleVertices = [self decomposeQuad:vertices];
    BOOL omittable = [self determineEligibilityForOmission:vertices];
    return [[GSFace alloc] initWithVertices:triangleVertices
                      correspondingCubeFace:face
                        eligibleForOmission:omittable];
}

+ (GSFace *)faceWithTri:(NSArray<GSBoxedTerrainVertex *> *)vertices correspondingCubeFace:(GSVoxelFace)face
{
    NSParameterAssert(vertices && vertices.count == 3);
    BOOL omittable = [self determineEligibilityForOmission:vertices];
    return [[GSFace alloc] initWithVertices:vertices
                      correspondingCubeFace:face
                        eligibleForOmission:omittable];
}

- (instancetype)init
{
    @throw nil;
    return nil;
}

- (instancetype)initWithVertices:(NSArray<GSBoxedTerrainVertex *> *)vertices
           correspondingCubeFace:(GSVoxelFace)face
             eligibleForOmission:(BOOL)omittable
{
    NSParameterAssert(vertices);
    NSParameterAssert(face >= 0 && face < FACE_NUM_FACES);

    self = [super init];
    if (self) {
        _vertexList = vertices;
        _correspondingCubeFace = face;
        _eligibleForOmission = omittable;
    }

    return self;
}

@end
