//
//  GSChunkVAO.m
//  GutsyStorm
//
//  Created by Andrew Fox on 3/17/13.
//  Copyright © 2013-2016 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <OpenGL/gl.h>

#import "GSGridItem.h"
#import "GSChunkVAO.h"
#import "GSIntegerVector3.h"
#import "GSChunkGeometryData.h"
#import "GSBoxedTerrainVertex.h"
#import "GSVBOHolder.h"
#import "GSVAOHolder.h"


#define SIZEOF_STRUCT_ARRAY_ELEMENT(t, m) sizeof(((t*)0)->m[0])


extern int checkGLErrors(void);


// Make sure the number of indices can be stored in the type used for the shared index buffer.
// NOTE: use a different value when index_t is GLushort.
static const GLsizei SHARED_INDEX_BUFFER_LEN = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z * 36;
typedef GLuint index_t;


@implementation GSChunkVAO
{
    GLsizei _numIndicesForDrawing;
    GSVBOHolder *_ibo;
    GSVAOHolder *_vao;
    NSOpenGLContext *_glContext;
    GSChunkGeometryData *_geometry;
    BOOL _initializedYet;
}

@synthesize cost;
@synthesize minP;

+ (nonnull GSVBOHolder *)sharedIndexBufferObject
{
    static dispatch_once_t onceToken;
    static GSVBOHolder *iboHolder;

    dispatch_once(&onceToken, ^{
        // Take the indices array and generate a raw index buffer that OpenGL can consume.
        index_t *buffer = malloc(sizeof(index_t) * SHARED_INDEX_BUFFER_LEN);
        if(!buffer) {
            [NSException raise:NSMallocException format:@"Out of memory allocating index buffer."];
        }

        for(GLsizei i = 0; i < SHARED_INDEX_BUFFER_LEN; ++i)
        {
            buffer[i] = i; // a simple linear walk
        }
        
        GLuint ibo = 0;
        
        glGenBuffers(1, &ibo);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, SHARED_INDEX_BUFFER_LEN * sizeof(index_t), buffer, GL_STATIC_DRAW);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        assert(checkGLErrors() == 0);
        
        iboHolder = [[GSVBOHolder alloc] initWithHandle:ibo context:[NSOpenGLContext currentContext]];
    });

    return iboHolder;
}

- (nonnull instancetype)initWithChunkGeometry:(nonnull GSChunkGeometryData *)geometry
                                     glContext:(nonnull NSOpenGLContext *)context
{
    NSParameterAssert(geometry);
    NSParameterAssert(context);

    if(self = [super init]) {
        _glContext = context;
        minP = geometry.minP;
        _geometry = geometry;
        _initializedYet = NO;
    }

    return self;
}

- (nonnull instancetype)copyWithZone:(nullable NSZone *)zone
{
    return self; // All GSChunkVAO objects are immutable, so return self instead of deep copying.
}

- (void)draw
{
    assert(checkGLErrors() == 0);
    assert(_numIndicesForDrawing < SHARED_INDEX_BUFFER_LEN);
    
    if (!_initializedYet) {
        _ibo = [[self class] sharedIndexBufferObject];
        
        GLuint vao = 0;
        glGenVertexArraysAPPLE(1, &vao);
        glBindVertexArrayAPPLE(vao);
        
        glEnableClientState(GL_VERTEX_ARRAY);
        glEnableClientState(GL_TEXTURE_COORD_ARRAY);
        glEnableClientState(GL_COLOR_ARRAY);
        
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _ibo.handle);
        
        GLuint vbo = 0;
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        
        GSTerrainVertexNoNormal *vertsBuffer = [_geometry copyVertsReturningCount:&_numIndicesForDrawing];
        GLsizeiptr bufferSize = _numIndicesForDrawing * sizeof(GSTerrainVertexNoNormal);
        cost = bufferSize;
        glBufferData(GL_ARRAY_BUFFER, bufferSize, vertsBuffer, GL_STATIC_DRAW);
        free(vertsBuffer);
        
        if (glGetError() == GL_OUT_OF_MEMORY) {
            NSLog(@"GSChunkVAO failed to acquire GPU resources.");
            glDeleteBuffers(1, &vbo);
            glDeleteVertexArraysAPPLE(1, &vao);
        } else {

#ifndef NDEBUG
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                // Verify that vertex attribute formats are consistent with in-memory storage.
                assert(sizeof(GLfloat) == SIZEOF_STRUCT_ARRAY_ELEMENT(GSTerrainVertexNoNormal, position));
                assert(sizeof(GLshort) == SIZEOF_STRUCT_ARRAY_ELEMENT(GSTerrainVertexNoNormal, texCoord));
                assert(sizeof(GLubyte) == SIZEOF_STRUCT_ARRAY_ELEMENT(GSTerrainVertexNoNormal, color));
            });
#endif
            
            const GLvoid *offsetVertex   = (const GLvoid *)offsetof(GSTerrainVertexNoNormal, position);
            const GLvoid *offsetTexCoord = (const GLvoid *)offsetof(GSTerrainVertexNoNormal, texCoord);
            const GLvoid *offsetColor    = (const GLvoid *)offsetof(GSTerrainVertexNoNormal, color);
            
            const GLsizei stride = sizeof(GSTerrainVertexNoNormal);
            glVertexPointer(  3, GL_FLOAT,         stride, offsetVertex);
            glTexCoordPointer(3, GL_SHORT,         stride, offsetTexCoord);
            glColorPointer(   4, GL_UNSIGNED_BYTE, stride, offsetColor);
            
            glBindVertexArrayAPPLE(0);
            
            _vao = [[GSVAOHolder alloc] initWithHandle:vao context:_glContext];
            
            glDeleteBuffers(1, &vbo);
            
            assert(checkGLErrors() == 0);
        }
        
        _initializedYet = YES;
        _geometry = nil; // don't need this anymore
    }

    GLenum indexEnum;
    if(2 == sizeof(index_t)) {
        indexEnum = GL_UNSIGNED_SHORT;
    } else if(4 == sizeof(index_t)) {
        indexEnum = GL_UNSIGNED_INT;
    } else {
        assert(!"I don't know the GLenum to use with index_t.");
    }

    glBindVertexArrayAPPLE(_vao.handle);
    glDrawElements(GL_TRIANGLES, _numIndicesForDrawing, indexEnum, NULL);
    glBindVertexArrayAPPLE(0);
    assert(checkGLErrors() == 0);
}

@end