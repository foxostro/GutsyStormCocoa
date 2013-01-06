//
//  GSChunkGeometryData.m
//  GutsyStorm
//
//  Created by Andrew Fox on 4/17/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import <GLKit/GLKMath.h>
#import "GSChunkGeometryData.h"
#import "GSChunkVoxelData.h"
#import "GSRay.h"
#import "GSChunkStore.h"
#import "GSVertex.h"
#import "Voxel.h"
#import "GSBlockMesh.h"
#import "GSBlockMeshMesh.h"
#import "GSBlockMeshCube.h"
#import "GSBlockMeshRamp.h"
#import "GSBlockMeshInsideCorner.h"
#import "GSBlockMeshOutsideCorner.h"
#import "GSBlockMeshEmpty.h"

#define SIZEOF_STRUCT_ARRAY_ELEMENT(t, m) sizeof(((t*)0)->m[0])

struct chunk_geometry_header
{
    uint8_t w, h, d;
    GLsizei numChunkVerts;
    uint32_t len;
};

extern int checkGLErrors(void);

static void drawChunkVBO(GLsizei numIndicesForDrawing, GLuint vbo);
static void syncDestroySingleVBO(NSOpenGLContext *context, GLuint vbo);
static void * allocateVertexMemory(size_t numVerts);
static void applyLightToVertices(size_t numChunkVerts,
                                 struct vertex *vertsBuffer,
                                 GSLightingBuffer *sunlight,
                                 GLKVector3 minP);

typedef GLint index_t;

// Make sure the number of indices can be stored in the type used for the shared index buffer.
static const GLsizei SHARED_INDEX_BUFFER_LEN = 200000; // NOTE: use a different value when index_t is GLushort.

@interface GSChunkGeometryData (Private)

+ (index_t *)sharedIndexBuffer;

- (void)destroyGeometry;
- (void)fillGeometryBuffersUsingVoxelData:(GSNeighborhood *)voxelData;
- (NSData *)dataRepr;
- (void)saveGeometryDataToFile;
- (NSError *)fillGeometryBuffersUsingDataRepr:(NSData *)data;
- (BOOL)tryToLoadGeometryFromFile;

@end

@implementation GSChunkGeometryData
{
    /* There are two copies of the index buffer so that one can be used for
     * drawing the chunk while geometry generation is in progress. This
     * removes the need to have any locking surrounding access to data
     * related to VBO drawing.
     */

    BOOL _needsVBORegeneration;
    GLsizei _numIndicesForDrawing;
    GLuint _vbo;

    NSConditionLock *_lockGeometry;
    GLsizei _numChunkVerts;
    struct vertex *_vertsBuffer;
    int _updateInFlight;

    NSURL *_folder;
    dispatch_group_t _groupForSaving;
    NSOpenGLContext *_glContext;
}

+ (id <GSBlockMesh>)sharedMeshFactoryWithBlockType:(voxel_type_t)type
{
    static id<GSBlockMesh> factories[NUM_VOXEL_TYPES];
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        GSBlockMeshEmpty *empty = [[GSBlockMeshEmpty alloc] init];

        for(voxel_type_t i=0; i<NUM_VOXEL_TYPES; ++i)
        {
            factories[i] = empty;
        }
        
        factories[VOXEL_TYPE_CUBE]           = [[GSBlockMeshCube alloc] init];
        factories[VOXEL_TYPE_RAMP]           = [[GSBlockMeshRamp alloc] init];
        factories[VOXEL_TYPE_CORNER_INSIDE]  = [[GSBlockMeshInsideCorner alloc] init];
        factories[VOXEL_TYPE_CORNER_OUTSIDE] = [[GSBlockMeshOutsideCorner alloc] init];
    });

    return factories[type];
}

+ (NSString *)fileNameForGeometryDataFromMinP:(GLKVector3)minP
{
    return [NSString stringWithFormat:@"%.0f_%.0f_%.0f.geometry.dat", minP.x, minP.y, minP.z];
}

- (id)initWithMinP:(GLKVector3)minP
            folder:(NSURL *)fldr
    groupForSaving:(dispatch_group_t)grpForSaving
    chunkTaskQueue:(dispatch_queue_t)chunkTaskQueue
         glContext:(NSOpenGLContext *)context
{
    self = [super initWithMinP:minP];
    if (self) {
        _glContext = context;
        [_glContext retain];
        
        _folder = fldr;
        [_folder retain];
        
        _groupForSaving = grpForSaving;
        dispatch_retain(_groupForSaving);
        
        // Geometry for the chunk is protected by lockGeometry and is generated asynchronously.
        _lockGeometry = [[NSConditionLock alloc] init];
        [_lockGeometry setName:@"GSChunkGeometryData.lockGeometry"];
        _vertsBuffer = NULL;
        _numChunkVerts = 0;
        _dirty = YES;
        _updateInFlight = 0;
        
        /* VBO data is not lock protected and is either exclusively accessed on the main thread
         * or is updated in ways that do not require locking for atomicity.
         */
        _vbo = 0;
        _numIndicesForDrawing = 0;
        _needsVBORegeneration = NO;
        
        // Frustum-Box testing requires the corners of the cube, so pre-calculate them here.
        _corners = malloc(sizeof(GLKVector3) * 8);
        if(!_corners) {
            [NSException raise:@"Out of Memory" format:@"Out of memory allocating _corners."];
        }

        _corners[0] = self.minP;
        _corners[1] = GLKVector3Add(_corners[0], GLKVector3Make(CHUNK_SIZE_X, 0,            0));
        _corners[2] = GLKVector3Add(_corners[0], GLKVector3Make(CHUNK_SIZE_X, 0,            CHUNK_SIZE_Z));
        _corners[3] = GLKVector3Add(_corners[0], GLKVector3Make(0,            0,            CHUNK_SIZE_Z));
        _corners[4] = GLKVector3Add(_corners[0], GLKVector3Make(0,            CHUNK_SIZE_Y, CHUNK_SIZE_Z));
        _corners[5] = GLKVector3Add(_corners[0], GLKVector3Make(CHUNK_SIZE_X, CHUNK_SIZE_Y, CHUNK_SIZE_Z));
        _corners[6] = GLKVector3Add(_corners[0], GLKVector3Make(CHUNK_SIZE_X, CHUNK_SIZE_Y, 0));
        _corners[7] = GLKVector3Add(_corners[0], GLKVector3Make(0,            CHUNK_SIZE_Y, 0));
        
        _visible = NO;
        
        // Try to load geometry from file so we have something to show before regeneration finishes.
        [self tryToLoadGeometryFromFile];
    }
    
    return self;
}

- (BOOL)tryToUpdateWithVoxelData:(GSNeighborhood *)neighborhood
{
    __block BOOL success = NO;
    
    if(!OSAtomicCompareAndSwapIntBarrier(0, 1, &_updateInFlight)) {
        DebugLog(@"Can't update geometry: already in-flight.");
        return NO; // an update is already in flight, so bail out now
    }
    
    void (^b)(void) = ^{
        __block BOOL anyNeighborHasDirtySunlight = NO;
        [neighborhood enumerateNeighborsWithBlock:^(GSChunkVoxelData *voxels) {
            if(voxels.dirtySunlight) {
                anyNeighborHasDirtySunlight = YES;
            }
        }];
        
        if(anyNeighborHasDirtySunlight) {
            OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
            DebugLog(@"Can't update geometry: a neighbor has dirty sunlight data.");
            return;
        }
        
        if(![_lockGeometry tryLock]) {
            OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
            DebugLog(@"Can't update geometry: lockGeometry is already taken.");
            return;
        }
        
        GSChunkVoxelData *center = [neighborhood neighborAtIndex:CHUNK_NEIGHBOR_CENTER];
        
        if([center.sunlight.lockLightingBuffer tryLockForReading]) {
            [self destroyGeometry];
            [self fillGeometryBuffersUsingVoxelData:neighborhood];
            [center.sunlight.lockLightingBuffer unlockForReading];
            
            // Need to set this flag so VBO rendering code knows that it needs to regenerate from geometry on next redraw.
            // Updating a boolean should be atomic on x86_64 and i386;
            _needsVBORegeneration = YES;
            
            // Cache geometry buffers on disk for next time.
            [self saveGeometryDataToFile];
            
            _dirty = NO;
            OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
            [_lockGeometry unlockWithCondition:READY];
            success = YES;
        } else {
            OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
            [_lockGeometry unlockWithCondition:!READY];
            DebugLog(@"Can't update geometry: sunlight buffer is busy.");
        }
    };
    
    if(![neighborhood tryReaderAccessToVoxelDataUsingBlock:b]) {
        OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
        DebugLog(@"Can't update geometry: voxel data buffers are busy.");
    }
    
    return success;
}

// Returns YES if VBOs were generated.
- (BOOL)drawGeneratingVBOsIfNecessary:(BOOL)allowVBOGeneration
{
    BOOL didGenerateVBOs = NO;
    
    if(allowVBOGeneration && _needsVBORegeneration && [_lockGeometry tryLockWhenCondition:READY]) {
        if(!_vbo) {
            glGenBuffers(1, &_vbo);
        }
        
        glBindBuffer(GL_ARRAY_BUFFER, _vbo);
        glBufferData(GL_ARRAY_BUFFER, _numChunkVerts * sizeof(struct vertex), _vertsBuffer, GL_STATIC_DRAW);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        
        _numIndicesForDrawing = _numChunkVerts;
        _needsVBORegeneration = NO; // reset
        didGenerateVBOs = YES;
        
        [_lockGeometry unlock];
    }
    
    drawChunkVBO(_numIndicesForDrawing, _vbo);

    return didGenerateVBOs;
}

- (void)dealloc
{
    dispatch_async(dispatch_get_main_queue(), ^{
        syncDestroySingleVBO(_glContext, _vbo);
    });
    
    [self destroyGeometry];
    [_lockGeometry release];
    [_glContext release];
    [_folder release];
    dispatch_release(_groupForSaving);
    free(_corners);
    [super dealloc];
}

@end

@implementation GSChunkGeometryData (Private)

+ (index_t *)sharedIndexBuffer
{
    static dispatch_once_t onceToken;
    static index_t *buffer;

    dispatch_once(&onceToken, ^{        
        // Take the indices array and generate a raw index buffer that OpenGL can consume.
        buffer = malloc(sizeof(index_t) * SHARED_INDEX_BUFFER_LEN);
        if(!buffer) {
            [NSException raise:@"Out of Memory" format:@"Out of memory allocating index buffer."];
        }
        
        for(GLsizei i = 0; i < SHARED_INDEX_BUFFER_LEN; ++i)
        {
            buffer[i] = i; // a simple linear walk
        }
    });
    
    return buffer;
}

/* Completely regenerate geometry for the chunk.
 *
 * Assumes caller is already holding the following locks:
 * "lockGeometry"
 * "lockVoxelData" for all chunks in the neighborhood (for reading).
 * "sunlight.lockLightingBuffer" for the center chunk in the neighborhood (for reading).
 */
- (void)fillGeometryBuffersUsingVoxelData:(GSNeighborhood *)neighborhood
{
    GLKVector3 pos;
    NSMutableArray *vertices;

    assert(neighborhood);

    GLKVector3 minP = self.minP;
    GLKVector3 maxP = self.maxP;

    vertices = [[NSMutableArray alloc] init];

    // Iterate over all voxels in the chunk and generate geometry.
    FOR_BOX(pos, minP, maxP)
    {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        GSIntegerVector3 chunkLocalPos = GSIntegerVector3_Make(pos.x-minP.x, pos.y-minP.y, pos.z-minP.z);
        GSChunkVoxelData *centerVoxels = [neighborhood neighborAtIndex:CHUNK_NEIGHBOR_CENTER];
        voxel_type_t type = [centerVoxels voxelAtLocalPosition:chunkLocalPos].type;
        id <GSBlockMesh> factory = [GSChunkGeometryData sharedMeshFactoryWithBlockType:type];

        [factory generateGeometryForSingleBlockAtPosition:pos
                                               vertexList:vertices
                                                voxelData:neighborhood
                                                     minP:minP];
        
        [pool release];
    }
    
    _numChunkVerts = (GLsizei)[vertices count];
    assert(numChunkVerts % 4 == 0); // chunk geometry is all done with quads

    // Take the vertices array and generate raw buffers for OpenGL to consume.
    _vertsBuffer = allocateVertexMemory(_numChunkVerts);
    for(GLsizei i=0; i<_numChunkVerts; ++i)
    {
        GSVertex *v = vertices[i];
        _vertsBuffer[i] = v.v;
    }

    [vertices release];

    // Iterate over all vertices and calculate lighting.
    applyLightToVertices(_numChunkVerts, _vertsBuffer,
                         [neighborhood neighborAtIndex:CHUNK_NEIGHBOR_CENTER].sunlight,
                         minP);
}

// Assumes the caller is already holding "lockGeometry".
- (void)destroyGeometry
{
    free(_vertsBuffer);
    _vertsBuffer = NULL;
    _numChunkVerts = 0;
}

// Assumes the caller is already holding "lockGeometry".
- (NSData *)dataRepr
{
    NSMutableData *data = [[[NSMutableData alloc] init] autorelease];
    
    struct chunk_geometry_header header;
    header.w = CHUNK_SIZE_X;
    header.h = CHUNK_SIZE_Y;
    header.d = CHUNK_SIZE_Z;
    header.numChunkVerts = _numChunkVerts;
    header.len = _numChunkVerts * sizeof(struct vertex);
    
    [data appendBytes:&header length:sizeof(header)];
    [data appendBytes:_vertsBuffer length:header.len];
    
    return data;
}

// Assumes the caller is already holding "lockGeometry".
- (void)saveGeometryDataToFile
{
    NSURL *url = [NSURL URLWithString:[GSChunkGeometryData fileNameForGeometryDataFromMinP:self.minP]
                        relativeToURL:_folder];
    
    [[self dataRepr] writeToURL:url atomically:YES];
}

// Assumes the caller is already holding "lockGeometry".
- (NSError *)fillGeometryBuffersUsingDataRepr:(NSData *)data
{
    struct chunk_geometry_header header;
    
    if(!data) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"Geometry data is nil."}];
    }
    
    [self destroyGeometry];
    
    [data getBytes:&header range:NSMakeRange(0, sizeof(struct chunk_geometry_header))];
    
    if((header.w != CHUNK_SIZE_X) || (header.h != CHUNK_SIZE_Y) || (header.d != CHUNK_SIZE_Z)) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"Geometry data is for chunk of the wrong size."}];
    }
    
    if(header.numChunkVerts <= 0) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"numChunkVerts <= 0"}];
    }
    
    if((header.numChunkVerts % 4) != 0) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"numChunkVerts%4 != 0"}];
    }
    
    const size_t expectedLen = header.numChunkVerts * sizeof(struct vertex);
    if(expectedLen != header.len) {
        return [NSError errorWithDomain:GSErrorDomain
                                   code:GSInvalidChunkDataOnDiskError
                               userInfo:@{NSLocalizedFailureReasonErrorKey:@"Geometry data length is not as unexpected."}];
    }
    
    _numChunkVerts = header.numChunkVerts;
    _vertsBuffer = allocateVertexMemory(_numChunkVerts);
    [data getBytes:_vertsBuffer range:NSMakeRange(sizeof(struct chunk_geometry_header), header.len)];
    
    return nil; // Success!
}

- (BOOL)tryToLoadGeometryFromFile
{
    BOOL success = NO;
    
    if(!OSAtomicCompareAndSwapIntBarrier(0, 1, &_updateInFlight)) {
        DebugLog(@"Can't load geometry: update already in-flight.");
        success = NO;
        goto cleanup1;
    }
    
    if(![_lockGeometry tryLock]) {
        DebugLog(@"Can't load geometry: lockGeometry is already taken.");
        success = NO;
        goto cleanup2;
    }
    
    NSString *path = [GSChunkGeometryData fileNameForGeometryDataFromMinP:self.minP];
    NSURL *url = [NSURL URLWithString:path relativeToURL:_folder];
    
    if(NO == [url checkResourceIsReachableAndReturnError:NULL]) {
        DebugLog(@"Can't load geometry: file not present.");
        success = NO;
        goto cleanup3;
    }
    
    NSError *error = [self fillGeometryBuffersUsingDataRepr:[NSData dataWithContentsOfURL:url]];
    if(nil != error) {
        DebugLog(@"Can't load geometry: %@", error.localizedDescription);
        success = NO;
        goto cleanup3;
    }
    
    // Success!
    _needsVBORegeneration = YES;
    _dirty = NO;
    success = YES;

cleanup3:
    [_lockGeometry unlockWithCondition:success?READY:!READY];
cleanup2:
    OSAtomicCompareAndSwapIntBarrier(1, 0, &_updateInFlight); // reset
cleanup1:
    return success;
}

@end

static void drawChunkVBO(GLsizei numIndicesForDrawing, GLuint vbo)
{
    if(!vbo) {
        return;
    }
    
    if(numIndicesForDrawing <= 0) {
        return;
    }

    // TODO: use VAOs
    
    const index_t const *indices = [GSChunkGeometryData sharedIndexBuffer]; // TODO: index buffer object
    
    assert(checkGLErrors() == 0);
    assert(numIndicesForDrawing < SHARED_INDEX_BUFFER_LEN);
    assert(indices);
    
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    
    // Verify that vertex attribute formats are consistent with in-memory storage.
    assert(sizeof(GLfloat) == SIZEOF_STRUCT_ARRAY_ELEMENT(struct vertex, position));
    assert(sizeof(GLbyte)  == SIZEOF_STRUCT_ARRAY_ELEMENT(struct vertex, normal));
    assert(sizeof(GLshort) == SIZEOF_STRUCT_ARRAY_ELEMENT(struct vertex, texCoord));
    assert(sizeof(GLubyte) == SIZEOF_STRUCT_ARRAY_ELEMENT(struct vertex, color));
    
    const GLvoid *offsetVertex   = (const GLvoid *)offsetof(struct vertex, position);
    const GLvoid *offsetNormal   = (const GLvoid *)offsetof(struct vertex, normal);
    const GLvoid *offsetTexCoord = (const GLvoid *)offsetof(struct vertex, texCoord);
    const GLvoid *offsetColor    = (const GLvoid *)offsetof(struct vertex, color);
    
    const GLsizei stride = sizeof(struct vertex);
    glVertexPointer(  3, GL_FLOAT,         stride, offsetVertex);
    glNormalPointer(     GL_BYTE,          stride, offsetNormal);
    glTexCoordPointer(3, GL_SHORT,         stride, offsetTexCoord);
    glColorPointer(   4, GL_UNSIGNED_BYTE, stride, offsetColor);

    GLenum indexEnum;
    if(2 == sizeof(index_t)) {
        indexEnum = GL_UNSIGNED_SHORT;
    } else if(4 == sizeof(index_t)) {
        indexEnum = GL_UNSIGNED_INT;
    } else {
        assert(!"I don't know the GLenum to use with index_t.");
    }

    glDrawElements(GL_QUADS, numIndicesForDrawing, indexEnum, indices);
    assert(checkGLErrors() == 0);
}

static void syncDestroySingleVBO(NSOpenGLContext *context, GLuint vbo)
{
    assert(context);
    if(vbo) {
        [context makeCurrentContext];
        CGLLockContext((CGLContextObj)[context CGLContextObj]); // protect against display link thread
        glDeleteBuffers(1, &vbo);
        CGLUnlockContext((CGLContextObj)[context CGLContextObj]);
    }
}

// Allocate a buffer for use in geometry generation and VBOs.
static void * allocateVertexMemory(size_t numVerts)
{
    assert(numVerts > 0);
    
    void *buffer = malloc(sizeof(struct vertex) * numVerts);
    if(!buffer) {
        [NSException raise:@"Out of Memory" format:@"Out of memory allocating chunk buffer."];
    }
    
    return buffer;
}

static void applyLightToVertices(size_t numChunkVerts,
                                 struct vertex *vertsBuffer,
                                 GSLightingBuffer *sunlight,
                                 GLKVector3 minP)
{
    assert(vertsBuffer);
    assert(sunlight);

    for(GLsizei i=0; i<numChunkVerts; ++i)
    {
        struct vertex *v = &vertsBuffer[i];
        
        GLKVector3 vertexPos = GLKVector3MakeWithArray(v->position);
        GSIntegerVector3 normal = GSIntegerVector3_MakeWithGLubyte3(v->normal);

        uint8_t sunlightValue = [sunlight lightForVertexAtPoint:vertexPos
                                                     withNormal:normal
                                                           minP:minP];

        GLKVector4 color = {0};

        color.g = 204.0f * (sunlightValue / (float)CHUNK_LIGHTING_MAX) + 51.0f; // sunlight in the green channel

        v->color[0] = color.v[0];
        v->color[1] = color.v[1];
        v->color[2] = color.v[2];
        v->color[3] = color.v[3];
    }
}
