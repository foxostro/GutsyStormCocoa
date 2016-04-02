//
//  GSGridEdit.m
//  GutsyStorm
//
//  Created by Andrew Fox on 10/10/15.
//  Copyright © 2015-2016 Andrew Fox. All rights reserved.
//

#import "GSGridEdit.h"

@implementation GSGridEdit

- (instancetype)initWithOriginalItem:(id)item
                        modifiedItem:(id)replacement
                                 pos:(vector_float3)p
{
    self = [super init];
    if (self) {
        _originalObject = item;
        _modifiedObject = replacement;
        _pos = p;
    }
    return self;
}

@end
