//
//  FoxIntegerVector3.h
//  GutsyStorm
//
//  Created by Andrew Fox on 4/18/12.
//  Copyright 2012-2015 Andrew Fox. All rights reserved.
//

#ifndef GutsyStorm_FoxIntegerVector3_h
#define GutsyStorm_FoxIntegerVector3_h

#import <simd/vector.h>

static inline vector_long3 GSMakeIntegerVector3(long x, long y, long z)
{
    return (vector_long3){x, y, z};
}

static const vector_long3 GSZeroIntVec3 = {0, 0, 0};

#endif