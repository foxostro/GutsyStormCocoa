//
//  GSTerrainBuffer.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/17/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GSIntegerVector3.h"
#import "GSVoxel.h"


typedef uint16_t GSTerrainBufferElement;


static inline size_t BUFFER_SIZE_IN_BYTES(vector_long3 dimensions)
{
    return dimensions.x * dimensions.y * dimensions.z * sizeof(GSTerrainBufferElement);
}


// Columns in the y-axis are contiguous in memory.
static inline size_t INDEX_INTO_LIGHTING_BUFFER(vector_long3 dimensions, vector_long3 p)
{
    return (p.x * dimensions.y * dimensions.z) + (p.z * dimensions.y) + (p.y);
}


@class GSTerrainBuffer;


typedef void (^GSBufferCompletionHandler)(GSTerrainBuffer * _Nonnull aBuffer, NSError * _Nullable error);


/* Represents a three-dimensional grid of bytes.
 * This can be used for myriad purposes including volumetric lighting values and voxel data.
 */
@interface GSTerrainBuffer : NSObject <NSCopying>
{
@protected
    vector_long3 _offsetFromChunkLocalSpace;
    GSTerrainBufferElement *_data;
}

@property (nonatomic, readonly) vector_long3 dimensions;

/* Creates a new GSTerrainBuffer and initializes it with data from file.
 * The dimensions of the buffer must be specified upfront in order to ensure the file contains the correct amount of
 * data. File I/O is performed asynchronously on the specified queue, and the new object is returned through the
 * completion handler block.
 * On error, the completion handler has aBuffer==nil and `error' provides details about the failure.
 */
+ (void)newBufferFromFile:(nonnull NSURL *)url
               dimensions:(vector_long3)dimensions
                    queue:(nonnull dispatch_queue_t)queue
        completionHandler:(nonnull GSBufferCompletionHandler)completionHandler;

/* Creates a new buffer of dimensions (CHUNK_SIZE_X+2) x (CHUNK_SIZE_Y) x (CHUNK_SIZE_Z+2).
 * The contents of the new buffer are initialized from the specified larger, raw buffer. Non-overlapping portions are
 * discarded.
 */
+ (nullable instancetype)newBufferFromLargerRawBuffer:(const GSTerrainBufferElement * _Nonnull)srcBuf
                                              srcMinP:(vector_long3)srcMinP
                                              srcMaxP:(vector_long3)srcMaxP;

/* Initialize a buffer of the specified dimensions */
- (nullable instancetype)initWithDimensions:(vector_long3)dim;

/* Initialize a buffer of the specified dimensions. The specified backing data is copied into the internal buffer. */
- (nullable instancetype)initWithDimensions:(vector_long3)dim data:(const GSTerrainBufferElement * _Nonnull)data;

/* Returns the value for the specified point in chunk-local space.
 * Always returns 0 for points which have no corresponding mapping in the buffer.
 */
- (GSTerrainBufferElement)valueAtPosition:(vector_long3)chunkLocalP;

/* Given a specific vertex position in the chunk, and a normal for that vertex, get the contribution of the (lighting)
 * buffer on the vertex.
 *
 * vertexPosInWorldSpace -- Vertex position in world space.
 * normal -- Vertex normal
 * minP -- Minimum corner of the chunk. This is the offset between world-space and chunk-local-space.
 *
 * As the lighting buffer has no knowledge of the neighboring chunks, expect values on the border to be incorrect.
 */
- (GSTerrainBufferElement)lightForVertexAtPoint:(vector_float3)vertexPosInWorldSpace
                                       withNormal:(vector_long3)normal
                                             minP:(vector_float3)minP;

/* Saves the buffer contents to file asynchronously on the specified dispatch */
- (void)saveToFile:(nonnull NSURL *)url
             queue:(nonnull dispatch_queue_t)queue
             group:(nonnull dispatch_group_t)group;

/* Copies this buffer into a sub-range of another buffer of dimensions defined by GSCombinedMinP and GSCombinedMaxP. */
- (void)copyToCombinedNeighborhoodBuffer:(nonnull GSTerrainBufferElement *)dstBuf
                                   count:(NSUInteger)count
                                neighbor:(GSVoxelNeighborIndex)neighbor;

- (nonnull GSTerrainBuffer *)copyWithEditAtPosition:(vector_long3)chunkLocalPos value:(GSTerrainBufferElement)value;

- (const GSTerrainBufferElement * _Nonnull)data;

@end