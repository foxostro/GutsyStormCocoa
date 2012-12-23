//
//  GSActiveRegion.h
//  GutsyStorm
//
//  Created by Andrew Fox on 9/14/12.
//  Copyright (c) 2012 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSChunkGeometryData.h"

@class GSCamera;

@interface GSActiveRegion : NSObject
{
    GLKVector3 activeRegionExtent; // The active region is specified relative to the camera position.
    NSUInteger maxActiveChunks;
    GSChunkGeometryData **activeChunks;
    NSLock *lock;
}

@property (readonly, nonatomic) NSUInteger maxActiveChunks;

- (id)initWithActiveRegionExtent:(GLKVector3)activeRegionExtent;
- (void)enumerateActiveChunkWithBlock:(void (^)(GSChunkGeometryData *))block;
- (NSArray *)pointsListSortedByDistFromCamera:(GSCamera *)camera unsortedList:(NSMutableArray *)unsortedPoints;
- (NSArray *)chunksListSortedByDistFromCamera:(GSCamera *)camera unsortedList:(NSMutableArray *)unsortedChunks;
- (void)enumeratePointsInActiveRegionNearCamera:(GSCamera *)camera usingBlock:(void (^)(GLKVector3 p))myBlock;
- (void)updateWithSorting:(BOOL)sorting
                   camera:(GSCamera *)camera
            chunkProducer:(GSChunkGeometryData * (^)(GLKVector3 p))chunkProducer;

@end
