//
//  GSNoise.h
//  GutsyStorm
//
//  Created by Andrew Fox on 3/24/12.
//  Copyright 2012 Andrew Fox. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface GSNoise : NSObject
{
    void *context;
}

- (id)initWithSeed:(unsigned)seed;
- (float)noiseAtPoint:(GLKVector3)p;
- (float)noiseAtPoint:(GLKVector3)p numOctaves:(unsigned)numOctaves;
- (float)noiseAtPointWithFourOctaves:(GLKVector3)p;

@end
