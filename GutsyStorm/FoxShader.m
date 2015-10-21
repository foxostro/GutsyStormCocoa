//
//  FoxShader.m
//  GutsyStorm
//
//  Created by Andrew Fox on 3/20/12.
//  Copyright 2012-2015 Andrew Fox. All rights reserved.
//

#import <assert.h>
#import "FoxShader.h"


extern int checkGLErrors(void);


@interface FoxShader ()

- (const GLchar **)buildSourceStringsArray:(NSString *)source
                                    length:(GLsizei *)length;

- (NSString *)shaderInfoLog:(GLuint)shader;
- (NSString *)programInfoLog:(GLuint)program;
- (BOOL)wasShaderCompileSuccessful:(GLuint)shader;
- (BOOL)wasProgramLinkSuccessful:(GLuint)shader;
- (void)createShaderWithSource:(NSString *)sourceString
                          type:(GLenum)type;
- (void)link;

@end


@implementation FoxShader
{
    GLuint _handle;
    BOOL _linked;
}

- (instancetype)initWithVertexShaderSource:(NSString *)vert
                      fragmentShaderSource:(NSString *)frag;
{
    self = [super init];
    if (self) {
        // Initialization code here.
        _handle = glCreateProgram();
        _linked = NO;
        
        [self createShaderWithSource:vert type:GL_VERTEX_SHADER];
        [self createShaderWithSource:frag type:GL_FRAGMENT_SHADER];
        [self link];
        assert(checkGLErrors() == 0);
    }
    
    return self;
}

- (void)bind
{
    glUseProgram(_handle);
}

- (void)unbind
{
    glUseProgram(0);
}

- (void)bindUniformWithInt:(GLint)value name:(NSString *)name
{
    // XXX: Could speed this up by storing the uniform location instead of searching for it every time.
    const GLchar *nameCStr = [name cStringUsingEncoding:NSMacOSRomanStringEncoding];
    GLint loc = glGetUniformLocation(_handle, nameCStr);
    glUniform1i(loc, value);
    assert(checkGLErrors() == 0);
}

- (void)bindUniformWithMatrix4x4:(matrix_float4x4)value name:(NSString *)name
{
    // XXX: Could speed this up by storing the uniform location instead of searching for it every time.
    const GLchar *nameCStr = [name cStringUsingEncoding:NSMacOSRomanStringEncoding];
    GLint loc = glGetUniformLocation(_handle, nameCStr);
    glUniformMatrix4fv(loc, 1, GL_TRUE, (float *)&value);
    assert(checkGLErrors() == 0);
}

- (void)bindUniformWithVector2:(vector_float2)value name:(NSString *)name
{
    // XXX: Could speed this up by storing the uniform location instead of searching for it every time.
    const GLchar *nameCStr = [name cStringUsingEncoding:NSMacOSRomanStringEncoding];
    GLint loc = glGetUniformLocation(_handle, nameCStr);
    glUniform2fv(loc, 1, (float *)&value);
    assert(checkGLErrors() == 0);
}

/* For OpenGL, build a C array where each element is a line (string) in the shader source.
 * Caller must free the returned array. Strings in the array will be autoreleased.
 * The length of the array is returned in length.
 */
- (const GLchar **)buildSourceStringsArray:(NSString *)source 
                                    length:(GLsizei *)length
{
    NSArray<NSString *> *lines = [source componentsSeparatedByString: @"\n"];
    NSUInteger count = [lines count];
    
    const GLchar **src = malloc(count * sizeof(const GLchar *));
    if(!src) {
        [NSException raise:@"Out of memory" format:@"Failed to malloc memory for src"];
    }
    
    NSEnumerator *e = [lines objectEnumerator];
    id object = nil;
    for(NSUInteger i = 0; (i < count) && (object = [e nextObject]); ++i)
    {
        src[i] = [object cStringUsingEncoding:NSMacOSRomanStringEncoding];
    }
    
    (*length) = (GLsizei)count;
    return src;
}

- (NSString *)shaderInfoLog:(GLuint)shader
{
    GLint errorLogLen = 0;
    
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &errorLogLen);
    
    char *buffer = malloc(errorLogLen);
    if(!buffer) {
        [NSException raise:@"Out of memory"
                    format:@"Failed to malloc memory for shader info log."];
    }
    
    glGetShaderInfoLog(shader, errorLogLen, NULL, buffer);
    
    NSString *infoLogStr = [NSString stringWithCString:buffer encoding:NSMacOSRomanStringEncoding];
    
    free(buffer);
    
    return infoLogStr;
}

- (NSString *)programInfoLog:(GLuint)program
{
    GLint errorLogLen = 0;
    
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &errorLogLen);
    
    char *buffer = malloc(errorLogLen);
    if(!buffer) {
        [NSException raise:@"Out of memory"
                    format:@"Failed to malloc memory for program info log."];
    }
    
    glGetProgramInfoLog(program, errorLogLen, NULL, buffer);
    
    NSString *infoLogStr = [NSString stringWithCString:buffer encoding:NSMacOSRomanStringEncoding];
    
    free(buffer);
    
    return infoLogStr;
}

- (BOOL)wasShaderCompileSuccessful:(GLuint)shader
{
    GLint status = 0;
    
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    
    // if compilation failed, print the log
    if(!status) {
        NSLog(@"Failed to compile shader object:\n%@", [self shaderInfoLog:shader]);
        return NO;
    } else {
        return YES;
    }
}

- (BOOL)wasProgramLinkSuccessful:(GLuint)program
{
    GLint status = 0;
    
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    
    // if compilation failed, print the log
    if(!status) {
        NSLog(@"Failed to link shader program:\n%@", [self programInfoLog:program]);
        return NO;
    } else {
        return YES;
    }
}

- (void)createShaderWithSource:(NSString *)sourceString type:(GLenum)type
{
    const GLchar *src = [sourceString cStringUsingEncoding:NSMacOSRomanStringEncoding];
    
    GLuint shader = glCreateShader(type);
    glAttachShader(_handle, shader);
    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    
    [self wasShaderCompileSuccessful:shader];
}

- (void)link
{
    glLinkProgram(_handle);
    _linked = [self wasProgramLinkSuccessful:_handle];
}

@end
