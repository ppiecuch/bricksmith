//
//  LDrawLSynth.h
//  Bricksmith
//
//  Created by Robin Macharg on 16/11/2012.
//
//

#import "LDrawContainer.h"
#import "LDrawDrawableElement.h"
#import "ColorLibrary.h"

@interface LDrawLSynth : LDrawContainer <LDrawColorable>
{
    NSMutableArray  *synthesizedParts;
    NSString        *lsynthType;
    int              lsynthClass;
    LDrawColor      *color;
    GLfloat			 glTransformation[16];
}

// Accessors
- (void) setLsynthClass:(int)lsynthClass;
- (void) setLsynthType:(NSString *)lsynthClass;
- (NSString *) lsynthType;
- (int) lsynthClass;
- (TransformComponents) transformComponents;

// Utilities
- (void)synthesize;
- (void) colorSynthesizedPartsTranslucent:(BOOL)yesNo;

@end