//==============================================================================
//
// File:		LDrawUtilities.h
//
// Purpose:		Convenience routines for managing LDraw directives.
//
//  Created by Allen Smith on 2/28/06.
//  Copyright 2006. All rights reserved.
//==============================================================================
#import <Cocoa/Cocoa.h>

#import "MatrixMath.h"

@class LDrawPart;

// How much parts move when you nudge them in the viewer. 
typedef enum gridSpacingMode
{
	gridModeFine	= 0,
	gridModeMedium	= 1,
	gridModeCoarse	= 2
} gridSpacingModeT;


// Viewing Angle
typedef enum
{
	ViewOrientation3D			= 0,
	ViewOrientationFront		= 1,
	ViewOrientationBack			= 2,
	ViewOrientationLeft			= 3,
	ViewOrientationRight		= 4,
	ViewOrientationTop			= 5,
	ViewOrientationBottom		= 6
	
} ViewOrientationT;



@interface LDrawUtilities : NSObject
{

}

+ (Tuple3) angleForViewOrientation:(ViewOrientationT)orientation;
+ (Box3) boundingBox3ForDirectives:(NSArray *)directives;
+ (Class) classForLineType:(int)lineType;
+ (NSImage *) dragImageWithOffset:(NSPointPointer)dragImageOffset;
+ (float) gridSpacingForMode:(gridSpacingModeT)gridMode;
+ (BOOL) isLDrawFilenameValid:(NSString *)fileName;
+ (NSString *) readNextField:(NSString *) partialDirective
				   remainder:(NSString **) remainder;
+ (NSString *) stringFromFile:(NSString *)path;
+ (void) updateNameForMovedPart:(LDrawPart *)movedPart;
+ (ViewOrientationT) viewOrientationForAngle:(Tuple3)rotationAngle;

@end
