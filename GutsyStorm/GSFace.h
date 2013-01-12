//
//  GSFace.h
//  GutsyStorm
//
//  Created by Andrew Fox on 1/12/13.
//  Copyright (c) 2013 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "Voxel.h"

@interface GSFace : NSObject

@property (readonly) BOOL eligibleForOmission;
@property (copy) NSArray *vertexList;
@property (copy) NSArray *reversedVertexList;
@property (readonly) face_t correspondingCubeFace;
@property (readonly) face_t reversedCorrespondingCubeFace;

+ (GSFace *)faceWithVertices:(NSArray *)vertices correspondingCubeFace:(face_t)face;

- (id)initWithVertices:(NSArray *)vertices correspondingCubeFace:(face_t)face;

@end
