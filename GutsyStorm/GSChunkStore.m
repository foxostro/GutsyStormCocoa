//
//  GSChunkStore.m
//  GutsyStorm
//
//  Created by Andrew Fox on 3/24/12.
//  Copyright © 2012-2016 Andrew Fox. All rights reserved.
//

#import "GSIntegerVector3.h"
#import "GSRay.h"
#import "GSCamera.h"
#import "GSActiveRegion.h"
#import "GSShader.h"
#import "GSChunkStore.h"
#import "GSBoxedVector.h"
#import "GSNeighborhood.h"
#import "GSChunkVAO.h"
#import "GSChunkGeometryData.h"
#import "GSChunkSunlightData.h"
#import "GSChunkVoxelData.h"
#import "GSGrid.h"
#import "GSMatrixUtils.h"
#import "GSActivity.h"
#import "GSTerrainJournal.h"
#import "GSTerrainJournalEntry.h"
#import "GSReaderWriterLock.h"
#import "GSGridSlot.h"

#import <OpenGL/gl.h>


#define ARRAY_LEN(a) (sizeof(a)/sizeof(a[0]))


@interface GSChunkStore ()

- (void)createGrids;
- (void)setupActiveRegionWithCamera:(nonnull GSCamera *)cam;

+ (nonnull NSURL *)newTerrainCacheFolderURL;
- (nonnull GSNeighborhood *)neighborhoodAtPoint:(vector_float3)p;
- (BOOL)tryToGetNeighborhoodAtPoint:(vector_float3)p neighborhood:(GSNeighborhood * _Nonnull * _Nonnull)neighborhood;

- (nonnull GSChunkGeometryData *)chunkGeometryAtPoint:(vector_float3)p;
- (nonnull GSChunkSunlightData *)chunkSunlightAtPoint:(vector_float3)p;
- (nonnull GSChunkVoxelData *)chunkVoxelsAtPoint:(vector_float3)p;

- (BOOL)tryToGetChunkVoxelsAtPoint:(vector_float3)p chunk:(GSChunkVoxelData * _Nonnull * _Nonnull)chunk;

@end


@implementation GSChunkStore
{
    GSGrid *_gridVAO;
    GSGrid *_gridGeometryData;
    GSGrid *_gridSunlightData;
    GSGrid *_gridVoxelData;
    dispatch_group_t _groupForSaving;
    dispatch_queue_t _queueForSaving;
    BOOL _chunkStoreHasBeenShutdown;
    GSCamera *_camera;
    NSURL *_folder;
    GSShader *_terrainShader;
    NSOpenGLContext *_glContext;
    GSTerrainJournal *_journal;
    GSTerrainProcessorBlock _generator;
    GSActiveRegion *_activeRegion;
    vector_float3 _activeRegionExtent; // The active region is specified relative to the camera position.
}

- (nonnull GSChunkVoxelData *)newVoxelChunkAtPoint:(vector_float3)pos
{
    vector_float3 minCorner = GSMinCornerForChunkAtPoint(pos);
    return [[GSChunkVoxelData alloc] initWithMinP:minCorner
                                           folder:_folder
                                   groupForSaving:_groupForSaving
                                   queueForSaving:_queueForSaving
                                          journal:_journal
                                        generator:_generator];
}

- (nonnull GSChunkSunlightData *)newSunlightChunkAtPoint:(vector_float3)pos
{
    vector_float3 minCorner = GSMinCornerForChunkAtPoint(pos);
    GSNeighborhood *neighborhood = [self neighborhoodAtPoint:minCorner];
    return [[GSChunkSunlightData alloc] initWithMinP:minCorner
                                              folder:_folder
                                      groupForSaving:_groupForSaving
                                      queueForSaving:_queueForSaving
                                        neighborhood:neighborhood];
}

- (nonnull GSChunkGeometryData *)newGeometryChunkAtPoint:(vector_float3)pos
{
    vector_float3 minCorner = GSMinCornerForChunkAtPoint(pos);
    GSChunkSunlightData *sunlight = [self chunkSunlightAtPoint:minCorner];
    return [[GSChunkGeometryData alloc] initWithMinP:minCorner
                                              folder:_folder
                                            sunlight:sunlight
                                      groupForSaving:_groupForSaving
                                      queueForSaving:_queueForSaving
                                        allowLoading:YES];
}

- (nonnull GSChunkVAO *)newVAOChunkAtPoint:(vector_float3)pos
{
    vector_float3 minCorner = GSMinCornerForChunkAtPoint(pos);
    GSChunkGeometryData *geometry = [self chunkGeometryAtPoint:minCorner];
    return [[GSChunkVAO alloc] initWithChunkGeometry:geometry
                                           glContext:_glContext];
}

- (void)createGrids
{
    assert(!_chunkStoreHasBeenShutdown);

    _gridVoxelData = [[GSGrid alloc] initWithName:@"gridVoxelData"];
    _gridSunlightData = [[GSGrid alloc] initWithName:@"gridSunlightData"];
    _gridGeometryData = [[GSGrid alloc] initWithName:@"gridGeometryData"];
    _gridVAO = [[GSGrid alloc] initWithName:@"gridVAO"];
}

- (nonnull NSSet<GSBoxedVector *> *)sunlightChunksInvalidatedByChangeAtPoint:(vector_float3)p
                                                              originalVoxels:(nonnull GSChunkVoxelData *)voxels1
                                                              modifiedVoxels:(nonnull GSChunkVoxelData *)voxels2
{
    // The caller must ensure that the grids stay consistent with one another during the call to this method.

    NSParameterAssert(voxels1);
    NSParameterAssert(voxels2);

    vector_float3 minP = GSMinCornerForChunkAtPoint(p);
    vector_long3 clpOfEdit = GSMakeIntegerVector3(p.x - minP.x, p.y - minP.y, p.z - minP.z);

    // If the change is deep enough into the interior of the block then the change cannot affect the neighbors.
    if (clpOfEdit.x >= CHUNK_LIGHTING_MAX && clpOfEdit.z >= CHUNK_LIGHTING_MAX &&
        clpOfEdit.x < (CHUNK_SIZE_X-CHUNK_LIGHTING_MAX) && clpOfEdit.z < (CHUNK_SIZE_Z-CHUNK_LIGHTING_MAX)) {
        return [NSSet setWithObject:[GSBoxedVector boxedVectorWithVector:minP]];
    }

    GSVoxel originalVoxel = [voxels1 voxelAtLocalPosition:clpOfEdit];
    GSVoxel modifiedVoxel = [voxels2 voxelAtLocalPosition:clpOfEdit];

    BOOL originalIsOpaque = originalVoxel.opaque;
    BOOL modifiedIsOpaque = modifiedVoxel.opaque;
    
    // If the original block was opaque, and the new block is opaque, then the change actually can be resolved by
    // updating sunlight for the one block that was modified, and nothing else.
    // If the original block was not-opaque and the new block is also not-opaque then the change can be resolved as in
    // the above case. Only one sunlight block needs to be updated.
    if (originalIsOpaque == modifiedIsOpaque) {
        return [NSSet setWithObject:[GSBoxedVector boxedVectorWithVector:minP]];
    }
    
    GSTerrainBufferElement m = CHUNK_LIGHTING_MAX;
    
    // If the original block was opaque, and the new block is not-opaque, then the change cannot propagate a further
    // distance than the difference between the the maximum and minimum adjacent light levels. Noting, however, that
    // light levels of opaque blocks must be ignored.
    //
    // If the original block was not-opaque and the new block is opaque then the change probably needs be resolved
    // by actually computing the sunlight propagation first. We have a few options here: We could assume the
    // propagation will continue for the maximum distance. We could perform a flood-fill throughout the chunk to
    // determine whether it would touch the neighboring chunks. Or, we could optimize for the special case where we
    // place an opaque block on top of an opaque block. In this particular case, which we expect to be common,
    // the max-min difference technique will work correctly.
    BOOL removingBlock = originalIsOpaque && !modifiedIsOpaque;
    
    BOOL bottomBlockIsOpaque;
    if (clpOfEdit.y >= 1) {
        GSVoxel bottomVoxel = [voxels2 voxelAtLocalPosition:(clpOfEdit + GSMakeIntegerVector3(0, -1, 0))];
        bottomBlockIsOpaque = bottomVoxel.opaque;
    } else {
        bottomBlockIsOpaque = NO;
    }

    if (removingBlock || bottomBlockIsOpaque) {
        GSTerrainBufferElement maxSunlight = 0, minSunlight = CHUNK_LIGHTING_MAX;
        
        // Is the edit on the border of the chunk? If so then testing the adjacent chunks would involve taking a lock on
        // the neighboring chunks. If that's the case then skip neighbor tests and assume the edit affects the full
        // range. We do this because, upon entering this method, we're already holding a lock on the stripe which
        // contains the chunk which contains the edit. If we attempt to take the lock on another voxel data chunk, and
        // both chunks reside on the same stripe, then taking the lock will cause a deadlock.
        if (clpOfEdit.x > 0 && clpOfEdit.z > 0 && clpOfEdit.x < (CHUNK_SIZE_X-1) && clpOfEdit.z < (CHUNK_SIZE_Z-1)) {
            vector_long3 adjacentPoints[] = {
                clpOfEdit,
                clpOfEdit + GSMakeIntegerVector3(+1,  0,  0),
                clpOfEdit + GSMakeIntegerVector3(-1,  0,  0),
                clpOfEdit + GSMakeIntegerVector3( 0, +1,  0),
                clpOfEdit + GSMakeIntegerVector3( 0, -1,  0),
                clpOfEdit + GSMakeIntegerVector3( 0,  0, +1),
                clpOfEdit + GSMakeIntegerVector3( 0,  0, -1)
            };

            GSChunkSunlightData *sunChunk = nil;
            GSGridSlot *slot = [_gridSunlightData slotAtPoint:p];
            [slot.lock lockForWriting];
            if (slot.item) {
                sunChunk = (GSChunkSunlightData *)slot.item;
            } else {
                sunChunk = [self newSunlightChunkAtPoint:p];
                slot.item = sunChunk;
            }
            [slot.lock unlockForWriting];

            for(size_t i = 0; i < ARRAY_LEN(adjacentPoints); ++i)
            {
                vector_long3 adjacentPoint = adjacentPoints[i];
                
                if (adjacentPoint.y >= 0 && adjacentPoint.y < CHUNK_SIZE_Y) {
                    GSVoxel voxel = [voxels1 voxelAtLocalPosition:adjacentPoint];
                    
                    if (!voxel.opaque) {
                        GSTerrainBufferElement sunlightLevel = [sunChunk.sunlight valueAtPosition:adjacentPoint];
                        maxSunlight = MAX(maxSunlight, sunlightLevel);
                        minSunlight = MIN(minSunlight, sunlightLevel);
                    }
                }
            }
            
            m = maxSunlight - minSunlight;
        }
    }

    NSArray *points = @[[GSBoxedVector boxedVectorWithVector:GSMinCornerForChunkAtPoint(p)],
                        [GSBoxedVector boxedVectorWithVector:GSMinCornerForChunkAtPoint(p + vector_make(+m,  0,  0))],
                        [GSBoxedVector boxedVectorWithVector:GSMinCornerForChunkAtPoint(p + vector_make(-m,  0,  0))],
                        [GSBoxedVector boxedVectorWithVector:GSMinCornerForChunkAtPoint(p + vector_make( 0,  0, +m))],
                        [GSBoxedVector boxedVectorWithVector:GSMinCornerForChunkAtPoint(p + vector_make( 0,  0, -m))],
                        ];
    NSSet *set = [NSSet setWithArray:points];
    return set;
}

- (void)setupActiveRegionWithCamera:(nonnull GSCamera *)cam
{
    assert(!_chunkStoreHasBeenShutdown);
    NSParameterAssert(cam);
    assert(_gridVAO);

    // Active region is bounded at y>=0.
    const NSInteger w = [[NSUserDefaults standardUserDefaults] integerForKey:@"ActiveRegionExtent"];
    _activeRegionExtent = vector_make(w, CHUNK_SIZE_Y, w);
    _activeRegion = [[GSActiveRegion alloc] initWithActiveRegionExtent:_activeRegionExtent camera:cam chunkStore:self];
}

- (nonnull instancetype)initWithJournal:(nonnull GSTerrainJournal *)journal
                                 camera:(nonnull GSCamera *)camera
                          terrainShader:(nonnull GSShader *)terrainShader
                              glContext:(nonnull NSOpenGLContext *)glContext
                              generator:(nonnull GSTerrainProcessorBlock)generator
{
    if (self = [super init]) {
        _folder = [GSChunkStore newTerrainCacheFolderURL];
        _groupForSaving = dispatch_group_create();
        _chunkStoreHasBeenShutdown = NO;
        _camera = camera;
        _terrainShader = terrainShader;
        _glContext = glContext;
        _generator = [generator copy];
        _journal = journal;
        _queueForSaving = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);

        [self createGrids];
        [self setupActiveRegionWithCamera:camera];
        
        // If the cache folder is empty then apply the journal to rebuild it.
        // Since rebuilding from the journal is expensive, we avoid doing unless we have no choice.
        // Also, this provides a pretty easy way for the user to force a rebuild when they need it.
        NSArray *cacheContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[_folder path] error:nil];
        if (!cacheContents || cacheContents.count == 0) {
            [self applyJournal:journal];
        }
    }
    
    return self;
}

- (void)shutdown
{
    assert(!_chunkStoreHasBeenShutdown);
    assert(_gridVoxelData);
    assert(_gridSunlightData);
    assert(_gridGeometryData);
    assert(_gridVAO);
    assert(_groupForSaving);
    assert(_queueForSaving);

    // Shutdown the active region, which maintains it's own queue of async updates.
    [_activeRegion shutdown];
    _activeRegion = nil;

    // Wait for save operations to complete.
    NSLog(@"Waiting for all chunk-saving tasks to complete.");
    dispatch_group_wait(_groupForSaving, DISPATCH_TIME_FOREVER);
    NSLog(@"All chunks have been saved.");
    
    // From this point on, we do not expect anyone to access the chunk store data.
    _chunkStoreHasBeenShutdown = YES;
    
    [_gridVoxelData evictAllItems];
    _gridVoxelData = nil;

    [_gridSunlightData evictAllItems];
    _gridSunlightData = nil;

    [_gridGeometryData evictAllItems];
    _gridGeometryData = nil;

    [_gridVAO evictAllItems];
    _gridVAO = nil;

    _groupForSaving = NULL;
    _queueForSaving = NULL;
}

- (void)drawActiveChunks
{
    assert(_terrainShader);
    assert(_activeRegion);

    matrix_float4x4 translation = GSMatrixFromTranslation(vector_make(0.5f, 0.5f, 0.5f));
    matrix_float4x4 modelView = matrix_multiply(translation, _camera.modelViewMatrix);
    matrix_float4x4 mvp = matrix_multiply(modelView, _camera.projectionMatrix);

    [_terrainShader bind];
    [_terrainShader bindUniformWithMatrix4x4:mvp name:@"mvp"];
    [_activeRegion draw];
    [_terrainShader unbind];
}

- (void)updateWithCameraModifiedFlags:(unsigned)flags
{
    assert(!_chunkStoreHasBeenShutdown);
    assert(_activeRegion);
    [_activeRegion updateWithCameraModifiedFlags:flags];
}

- (void)applyJournal:(nonnull GSTerrainJournal *)journal
{
    NSParameterAssert(journal);

    assert(!_chunkStoreHasBeenShutdown);
    
    GSStopwatchTraceBegin(@"applyJournal");
    
    for(GSTerrainJournalEntry *entry in journal.journalEntries)
    {
        [self placeBlockAtPoint:[entry.position vectorValue] block:entry.value addToJournal:NO];
    }

    dispatch_group_wait(_groupForSaving, DISPATCH_TIME_FOREVER);
    GSStopwatchTraceEnd(@"applyJournal");
}

- (void)placeBlockAtPoint:(vector_float3)pos block:(GSVoxel)block addToJournal:(BOOL)addToJournal
{
    assert(!_chunkStoreHasBeenShutdown);
    assert(_gridVoxelData);
    assert(_activeRegion);
    assert(_journal);
    
    /* XXX: There's definitely a threading hazard here that needs to be addressed with better synchronization.
     * What if a grid access is interleaved with the call to -placeBlockAtPoint:block:? Couldn't this cause an incorrect
     * chunk to be generated and inserted into grids? What if two calls to -placeBlockAtPoint:block: overlap?
     */
    
    /* XXX: This will probably go better if we fetch all the slots we need, lock all the slots we need, and then
     * update the items within, before finally releasing all the slots at the end.
     */
    
    GSBoxedVector *boxedPos = [GSBoxedVector boxedVectorWithVector:pos];
    
    if (addToJournal) {
        dispatch_group_async(_groupForSaving, _queueForSaving, ^{
            GSTerrainJournalEntry *entry = [[GSTerrainJournalEntry alloc] init];
            entry.value = block;
            entry.position = boxedPos;
            [_journal addEntry:entry];
        });
    }

    GSStopwatchTraceBegin(@"placeBlockAtPoint enter %@", boxedPos);

    GSChunkVoxelData *voxels1 = nil;
    GSChunkVoxelData *voxels2 = nil;

    GSGridSlot *voxelSlot = [_gridVoxelData slotAtPoint:pos];
    [voxelSlot.lock lockForWriting];
    voxels1 = (GSChunkVoxelData *)voxelSlot.item;
    if (!voxels1) {
        voxels1 = [self newVoxelChunkAtPoint:pos];
    } else {
        [voxels1 invalidate];
        voxels2 = [voxels1 copyWithEditAtPoint:pos block:block];
        [voxels2 saveToFile];
        voxelSlot.item = voxels2;
    }
    [voxelSlot.lock unlockForWriting];
    
    GSStopwatchTraceStep(@"Updated voxels.");

    GSNeighborhood *neighborhood = [self neighborhoodAtPoint:pos];

    /* XXX: Consider replacing sunlightChunksInvalidatedByVoxelChangeAtPoint with a flood-fill constrained to the
     * local neighborhood. If the flood-fill would exit the center chunk then take note of which chunk because that
     * one needs invalidation too.
     */
    NSSet<GSBoxedVector *> *points = [self sunlightChunksInvalidatedByChangeAtPoint:pos
                                                                     originalVoxels:voxels1
                                                                     modifiedVoxels:voxels2];
    GSStopwatchTraceStep(@"Estimated affected sunlight chunks: %@", points);

    for(GSBoxedVector *bp in points)
    {
        vector_float3 p = [bp vectorValue];
        
        GSChunkSunlightData *sunlight2 = nil;
        GSChunkGeometryData *geo2 = nil;

        // Update sunlight.
        {
            GSGridSlot *sunSlot = [_gridSunlightData slotAtPoint:p];
            [sunSlot.lock lockForWriting];
            GSChunkSunlightData *sunlight1 = (GSChunkSunlightData *)sunSlot.item;
            if (sunlight1) {
                /* XXX: Potential performance improvement here. The copyWithEdit method can be made faster by only
                 * re-propagating sunlight in the region affected by the edit; not across the entire chunk.
                 */
                [sunlight1 invalidate];
                sunlight2 = [sunlight1 copyWithEditAtPoint:pos neighborhood:neighborhood];
            } else {
                sunlight2 = [self newSunlightChunkAtPoint:pos];
            }
            sunSlot.item = sunlight2;
            [sunSlot.lock unlockForWriting];
        }
        GSStopwatchTraceStep(@"Updated sunlight at %@", bp);

        // Update geometry.
        {
            GSGridSlot *geoSlot = [_gridGeometryData slotAtPoint:p];
            [geoSlot.lock lockForWriting];
            GSChunkGeometryData *geo1 = (GSChunkGeometryData *)geoSlot.item;
            if (geo1) {
                /* XXX: Potential performance improvement here. The copyWithEdit method can be made faster by only
                 * re-propagating sunlight in the region affected by the edit; not across the entire chunk.
                 */
                [geo1 invalidate];
                geo2 = [geo1 copyWithSunlight:sunlight2];
            } else {
                vector_float3 minCorner = GSMinCornerForChunkAtPoint(p);
                geo2 = [[GSChunkGeometryData alloc] initWithMinP:minCorner
                                                          folder:_folder
                                                        sunlight:sunlight2
                                                  groupForSaving:_groupForSaving
                                                  queueForSaving:_queueForSaving
                                                    allowLoading:NO];
            }
            geoSlot.item = geo2;
            [geoSlot.lock unlockForWriting];
        }
        GSStopwatchTraceStep(@"Updated geometry at %@", bp);

        // Update the Vertex Array Object.
        {
            GSGridSlot *vaoSlot = [_gridVAO slotAtPoint:p];
            [vaoSlot.lock lockForWriting];
            [vaoSlot.item invalidate];
            GSChunkVAO *vao2 = [[GSChunkVAO alloc] initWithChunkGeometry:geo2 glContext:_glContext];
            vaoSlot.item = vao2;
            [vaoSlot.lock unlockForWriting];
        }
        GSStopwatchTraceStep(@"Updated VAO at %@", bp);
    }

    GSStopwatchTraceEnd(@"placeBlockAtPoint exit %@", boxedPos);
}

- (nullable GSChunkVAO *)tryToGetVaoAtPoint:(vector_float3)pos
{
    if (_chunkStoreHasBeenShutdown) {
        return nil;
    }

    GSGridSlot *slot = [_gridVAO slotAtPoint:pos blocking:NO];
    
    if (!(slot && [slot.lock tryLockForReading])) {
        return nil;
    }
    
    GSChunkVAO *vao = (GSChunkVAO *)slot.item;
    
    [slot.lock unlockForReading];
    
    return vao;
}

- (nullable GSChunkVAO *)nonBlockingVaoAtPoint:(GSBoxedVector *)pos createIfMissing:(BOOL)createIfMissing
{
    if (_chunkStoreHasBeenShutdown) {
        return nil;
    }
    
    vector_float3 p = [pos vectorValue];
    GSGridSlot *slot = [_gridVAO slotAtPoint:p blocking:NO];
    
    if (!(slot && [slot.lock tryLockForWriting])) {
        return nil;
    }
    
    GSChunkVAO *vao = (GSChunkVAO *)slot.item;
    
    if (!vao) {
        vao = [self newVAOChunkAtPoint:p];
        slot.item = vao;
    }
    
    [slot.lock unlockForWriting];
    
    return vao;
}

- (BOOL)tryToGetVoxelAtPoint:(vector_float3)pos voxel:(nonnull GSVoxel *)voxel
{
    GSChunkVoxelData *chunk = nil;

    assert(!_chunkStoreHasBeenShutdown);
    assert(voxel);

    if(![self tryToGetChunkVoxelsAtPoint:pos chunk:&chunk]) {
        return NO;
    }

    assert(chunk);

    *voxel = [chunk voxelAtLocalPosition:GSMakeIntegerVector3(pos.x-chunk.minP.x,
                                                               pos.y-chunk.minP.y,
                                                               pos.z-chunk.minP.z)];
    
    return YES;
}

- (GSVoxel)voxelAtPoint:(vector_float3)pos
{
    assert(!_chunkStoreHasBeenShutdown);

    GSChunkVoxelData *chunk = [self chunkVoxelsAtPoint:pos];

    assert(chunk);

    return [chunk voxelAtLocalPosition:GSMakeIntegerVector3(pos.x-chunk.minP.x,
                                                             pos.y-chunk.minP.y,
                                                             pos.z-chunk.minP.z)];
}

- (BOOL)enumerateVoxelsOnRay:(GSRay)ray
                    maxDepth:(unsigned)maxDepth
                   withBlock:(void (^ _Nonnull)(vector_float3 p, BOOL * _Nonnull stop, BOOL * _Nonnull fail))block
{
    assert(!_chunkStoreHasBeenShutdown);

    /* Implementation is based on:
     * "A Fast Voxel Traversal Algorithm for Ray Tracing"
     * John Amanatides, Andrew Woo
     * http://www.cse.yorku.ca/~amana/research/grid.pdf
     *
     * See also: http://www.xnawiki.com/index.php?title=Voxel_traversal
     */
    
    // NOTES:
    // * This code assumes that the ray's position and direction are in 'cell coordinates', which means
    //   that one unit equals one cell in all directions.
    // * When the ray doesn't start within the voxel grid, calculate the first position at which the
    //   ray could enter the grid. If it never enters the grid, there is nothing more to do here.
    // * Also, it is important to test when the ray exits the voxel grid when the grid isn't infinite.
    // * The Point3D structure is a simple structure having three integer fields (X, Y and Z).
    
    // The cell in which the ray starts.
    vector_long3 start = GSMakeIntegerVector3(floorf(ray.origin.x), floorf(ray.origin.y), floorf(ray.origin.z));
    int x = (int)start.x;
    int y = (int)start.y;
    int z = (int)start.z;
    
    // Determine which way we go.
    int stepX = (ray.direction.x<0) ? -1 : (ray.direction.x==0) ? 0 : +1;
    int stepY = (ray.direction.y<0) ? -1 : (ray.direction.y==0) ? 0 : +1;
    int stepZ = (ray.direction.z<0) ? -1 : (ray.direction.z==0) ? 0 : +1;
    
    // Calculate cell boundaries. When the step (i.e. direction sign) is positive,
    // the next boundary is AFTER our current position, meaning that we have to add 1.
    // Otherwise, it is BEFORE our current position, in which case we add nothing.
    vector_long3 cellBoundary = GSMakeIntegerVector3(x + (stepX > 0 ? 1 : 0),
                                                          y + (stepY > 0 ? 1 : 0),
                                                          z + (stepZ > 0 ? 1 : 0));
    
    // NOTE: For the following calculations, the result will be Single.PositiveInfinity
    // when ray.Direction.X, Y or Z equals zero, which is OK. However, when the left-hand
    // value of the division also equals zero, the result is Single.NaN, which is not OK.
    
    // Determine how far we can travel along the ray before we hit a voxel boundary.
    vector_float3 tMax = vector_make((cellBoundary.x - ray.origin.x) / ray.direction.x,    // Boundary is a plane on the YZ axis.
                                    (cellBoundary.y - ray.origin.y) / ray.direction.y,    // Boundary is a plane on the XZ axis.
                                    (cellBoundary.z - ray.origin.z) / ray.direction.z);   // Boundary is a plane on the XY axis.
    if(isnan(tMax.x)) { tMax.x = +INFINITY; }
    if(isnan(tMax.y)) { tMax.y = +INFINITY; }
    if(isnan(tMax.z)) { tMax.z = +INFINITY; }

    // Determine how far we must travel along the ray before we have crossed a gridcell.
    vector_float3 tDelta = vector_make(stepX / ray.direction.x,                    // Crossing the width of a cell.
                                      stepY / ray.direction.y,                    // Crossing the height of a cell.
                                      stepZ / ray.direction.z);                   // Crossing the depth of a cell.
    if(isnan(tDelta.x)) { tDelta.x = +INFINITY; }
    if(isnan(tDelta.y)) { tDelta.y = +INFINITY; }
    if(isnan(tDelta.z)) { tDelta.z = +INFINITY; }
    
    // For each step, determine which distance to the next voxel boundary is lowest (i.e.
    // which voxel boundary is nearest) and walk that way.
    for(int i = 0; i < maxDepth; i++)
    {
        if(y >= _activeRegionExtent.y || y < 0) {
            return YES; // The vertical extent of the world is limited.
        }
        
        BOOL stop = NO;
        BOOL fail = NO;
        block(vector_make(x, y, z), &stop, &fail);

        if(fail) {
            return NO; // the block was going to block so it stopped and called for an abort
        }

        if(stop) {
            return YES;
        }
        
        // Do the next step.
        if (tMax.x < tMax.y && tMax.x < tMax.z) {
            // tMax.X is the lowest, an YZ cell boundary plane is nearest.
            x += stepX;
            tMax.x += tDelta.x;
        } else if (tMax.y < tMax.z) {
            // tMax.Y is the lowest, an XZ cell boundary plane is nearest.
            y += stepY;
            tMax.y += tDelta.y;
        } else {
            // tMax.Z is the lowest, an XY cell boundary plane is nearest.
            z += stepZ;
            tMax.z += tDelta.z;
        }
    }

    return YES;
}

- (nonnull GSNeighborhood *)neighborhoodAtPoint:(vector_float3)p
{
    assert(!_chunkStoreHasBeenShutdown);

    GSNeighborhood *neighborhood = [[GSNeighborhood alloc] init];

    for(GSVoxelNeighborIndex i = 0; i < CHUNK_NUM_NEIGHBORS; ++i)
    {
        vector_float3 a = p + [GSNeighborhood offsetForNeighborIndex:i];
        GSChunkVoxelData *voxels = [self chunkVoxelsAtPoint:a]; // NOTE: may block
        assert(voxels);
        [neighborhood setNeighborAtIndex:i neighbor:voxels];
    }
    
    return neighborhood;
}

- (BOOL)tryToGetNeighborhoodAtPoint:(vector_float3)p
                       neighborhood:(GSNeighborhood * _Nonnull * _Nonnull)outNeighborhood
{
    assert(!_chunkStoreHasBeenShutdown);
    NSParameterAssert(outNeighborhood);

    GSNeighborhood *neighborhood = [[GSNeighborhood alloc] init];

    for(GSVoxelNeighborIndex i = 0; i < CHUNK_NUM_NEIGHBORS; ++i)
    {
        vector_float3 a = p + [GSNeighborhood offsetForNeighborIndex:i];
        GSChunkVoxelData *voxels = nil;

        if(![self tryToGetChunkVoxelsAtPoint:a chunk:&voxels]) {
            return NO;
        }

        assert(voxels);

        [neighborhood setNeighborAtIndex:i neighbor:voxels];
    }

    *outNeighborhood = neighborhood;
    return YES;
}

- (nonnull GSChunkGeometryData *)chunkGeometryAtPoint:(vector_float3)p
{
    assert(!_chunkStoreHasBeenShutdown);
    assert(p.y >= 0 && p.y < _activeRegionExtent.y);
    assert(_gridGeometryData);

    GSChunkGeometryData *geo = nil;
    GSGridSlot *slot = [_gridGeometryData slotAtPoint:p];

    [slot.lock lockForWriting];
    if (slot.item) {
        geo = (GSChunkGeometryData *)slot.item;
    } else {
        geo = [self newGeometryChunkAtPoint:p];
        slot.item = geo;
    }
    [slot.lock unlockForWriting];

    return geo;
}

- (nonnull GSChunkSunlightData *)chunkSunlightAtPoint:(vector_float3)p
{
    assert(!_chunkStoreHasBeenShutdown);
    NSParameterAssert(p.y >= 0 && p.y < _activeRegionExtent.y);
    assert(_gridSunlightData);
    
    GSChunkSunlightData *sunlight = nil;
    GSGridSlot *slot = [_gridSunlightData slotAtPoint:p];
    
    [slot.lock lockForWriting];
    if (slot.item) {
        sunlight = (GSChunkSunlightData *)slot.item;
    } else {
        sunlight = [self newSunlightChunkAtPoint:p];
        slot.item = sunlight;
    }
    [slot.lock unlockForWriting];
    
    return sunlight;
}

- (nonnull GSChunkVoxelData *)chunkVoxelsAtPoint:(vector_float3)p
{
    assert(!_chunkStoreHasBeenShutdown);
    NSParameterAssert(p.y >= 0 && p.y < _activeRegionExtent.y);
    assert(_gridVoxelData);
    
    GSChunkVoxelData *voxels = nil;
    GSGridSlot *slot = [_gridVoxelData slotAtPoint:p];
    
    [slot.lock lockForWriting];
    if (slot.item) {
        voxels = (GSChunkVoxelData *)slot.item;
    } else {
        voxels = [self newVoxelChunkAtPoint:p];
        slot.item = voxels;
    }
    [slot.lock unlockForWriting];
    
    return voxels;
}

- (BOOL)tryToGetChunkVoxelsAtPoint:(vector_float3)p chunk:(GSChunkVoxelData * _Nonnull * _Nonnull)chunk
{
    assert(!_chunkStoreHasBeenShutdown);
    NSParameterAssert(p.y >= 0 && p.y < _activeRegionExtent.y);
    NSParameterAssert(chunk);
    assert(_gridVoxelData);

    GSGridSlot *slot = [_gridVoxelData slotAtPoint:p blocking:NO];
    
    if (!slot) {
        return NO;
    }
    
    if(![slot.lock tryLockForReading]) {
        return NO;
    }

    GSChunkVoxelData *voxels = (GSChunkVoxelData *)slot.item;
    if (voxels) {
        *chunk = voxels;
    }

    [slot.lock unlockForReading];
    
    return (voxels != nil);
}

+ (nonnull NSURL *)newTerrainCacheFolderURL
{
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *folder = ([paths count] > 0) ? paths[0] : NSTemporaryDirectory();
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];

    folder = [folder stringByAppendingPathComponent:bundleIdentifier];
    folder = [folder stringByAppendingPathComponent:@"terrain-cache"];
    NSLog(@"ChunkStore will cache terrain data in folder: %@", folder);
    
    if(![[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL]) {
        NSLog(@"Failed to create terrain cache folder: %@", folder);
    }
    
    NSURL *url = [[NSURL alloc] initFileURLWithPath:folder isDirectory:YES];
    
    if(![url checkResourceIsReachableAndReturnError:NULL]) {
        NSLog(@"ChunkStore's terrain cache folder is not reachable: %@", folder);
    }
    
    return url;
}

- (void)memoryPressure:(dispatch_source_memorypressure_flags_t)status
{
    if (_chunkStoreHasBeenShutdown) {
        return;
    }

    switch(status)
    {
        case DISPATCH_MEMORYPRESSURE_NORMAL:
            _gridVoxelData.countLimit = 0;
            _gridSunlightData.countLimit = 0;
            _gridGeometryData.countLimit = 0;
            _gridVAO.countLimit = 0;
            break;
            
        case DISPATCH_MEMORYPRESSURE_WARN:
            _gridVoxelData.countLimit = _gridVoxelData.count;
            _gridSunlightData.countLimit = _gridSunlightData.count;
            _gridGeometryData.countLimit = _gridGeometryData.count;
            _gridVAO.countLimit = _gridVAO.count;
            break;
            
        case DISPATCH_MEMORYPRESSURE_CRITICAL:
            _gridVoxelData.countLimit = _gridVoxelData.count;
            _gridSunlightData.countLimit = _gridSunlightData.count;
            _gridGeometryData.countLimit = _gridGeometryData.count;
            _gridVAO.countLimit = _gridVAO.count;
            
            [_gridVoxelData evictAllItems];
            [_gridSunlightData evictAllItems];
            [_gridGeometryData evictAllItems];
            [_gridVAO evictAllItems];
            [_activeRegion clearDrawList];
            break;
    }
}

- (void)printInfo
{
    NSLog(@"Chunk Store:\n\t%@\n\t%@\n\t%@\n\t%@", _gridVoxelData, _gridSunlightData, _gridGeometryData, _gridVAO);
}

@end