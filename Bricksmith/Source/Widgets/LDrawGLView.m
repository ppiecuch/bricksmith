//==============================================================================
//
// File:		LDrawGLView.m
//
// Purpose:		Draws an LDrawFile with OpenGL.
//
//				We also handle processing of user events related to the 
//				document. Certain interactions must be handed off to an 
//				LDrawDocument in order for them to effect the object being 
//				drawn. 
//
//				This class also provides for a number of mouse-based viewing 
//				tools triggered by hotkeys. However, we don't track them here! 
//				(We want *all* LDrawGLViews to respond to hotkeys at once.) So 
//				there is a symbiotic relationship with ToolPalette to track 
//				which tool mode we're in; we get notifications when it changes.
//
// Threading:	LDrawGLView spawns a separate thread to draw. There are two 
//				critical pieces of shared data which must be protected by 
//				mutual-exclusion locks:
//				
//					* the NSOpenGLContext
//
//					* the contents of the directive being drawn
//						--	I kinda cheated on this one. Only LDrawFiles 
//							automatically maintain mutexes. It's a safe shortcut
//							because only Files are edited! The editor must track 
//							the lock manually.
//
//  Created by Allen Smith on 4/17/05.
//  Copyright 2005. All rights reserved.
//==============================================================================
#import "LDrawGLView.h"

#import <GLUT/glut.h>
#import <OpenGL/glu.h>

#import "LDrawApplication.h"
#import "LDrawColor.h"
#import "LDrawDirective.h"
#import "LDrawDocument.h"
#import "LDrawFile.h"
#import "LDrawModel.h"
#import "LDrawPart.h"
#import "LDrawStep.h"
#import "LDrawUtilities.h"
#import "MacLDraw.h"
#import "ScrollViewCategory.h"
#import "UserDefaultsCategory.h"

@implementation LDrawGLView

//========== awakeFromNib ======================================================
//
// Purpose:		Set up our Cocoa viewing.
//
// Notes:		This method will get called twice: once because we load our 
//				accessory view from a Nib file, and once when this object is 
//				unpacked from the Nib in which it's stored.
//
//==============================================================================
- (void) awakeFromNib
{
	id		superview	= [self superview];
	NSRect	frame		= [self frame];
	
	// If we are in a scroller, make sure we appear centered when smaller than 
	// the scroll view. 
	[[self enclosingScrollView] centerDocumentView];

	if([superview isKindOfClass:[NSClipView class]])
	{
		//Center the view inside its scrollers.
		[self scrollCenterToPoint:NSMakePoint( NSWidth(frame)/2, NSHeight(frame)/2 )];
		[superview setCopiesOnScroll:NO];
	}
	
	
	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	
	[notificationCenter addObserver:self
						   selector:@selector(mouseToolDidChange:)
							   name:LDrawMouseToolDidChangeNotification
							 object:nil ];
	
	[notificationCenter addObserver:self
						   selector:@selector(backgroundColorDidChange:)
							   name:LDrawViewBackgroundColorDidChangeNotification
							 object:nil ];
	
	// Drag and Drop support. We only accept drags if we have a document to add 
	// them to. 
	if(self->document != nil)
		[self registerForDraggedTypes:[NSArray arrayWithObject:LDrawDraggingPboardType]];
	
	//Machinery needed to draw Quartz overtop OpenGL. Sadly, it caused our view 
	// to become transparent when minimizing to the dock. In the end, I didn't 
	// need it anyway.
//	long backgroundOrder = -1;
//	[[self openGLContext] setValues:&backgroundOrder forParameter: NSOpenGLCPSurfaceOrder];
//
//
//	NSScrollView *scrollView = [self enclosingScrollView];
//	if(scrollView != nil){
//		NSLog(@"making stuff transparent");
//		[[self window] setOpaque:NO];
//		[[self window] setAlphaValue:.999f];
////		[[self superview] setDrawsBackground:NO];
////		[scrollView setDrawsBackground:NO];
//	}
	
}//end awakeFromNib

#pragma mark -
#pragma mark INITIALIZATION
#pragma mark -

//========== initWithCoder: ====================================================
//
// Purpose:		Set up the beatiful OpenGL view.
//
//==============================================================================
- (id) initWithCoder: (NSCoder *) coder
{	
	NSOpenGLPixelFormatAttribute	pixelAttributes[]	= { NSOpenGLPFADoubleBuffer,
															NSOpenGLPFADepthSize,		32,
															NSOpenGLPFASampleBuffers,	1, // enable line antialiasing
															NSOpenGLPFASamples,			3, // antialiasing beauty
															0};
	NSOpenGLContext					*context			= nil;
	NSOpenGLPixelFormat				*pixelFormat		= nil;
	GLint							 swapInterval		= 1;
	
	self = [super initWithCoder: coder];
	
	// Yes, we have a nib file. Don't laugh. This view has accessories.
	[NSBundle loadNibNamed:@"LDrawGLViewAccessories" owner:self];
	
	[self setAcceptsFirstResponder:YES];
	[self setLDrawColor:LDrawCurrentColor];
	cameraDistance			= -10000;
	isTrackingDrag			= NO;
	projectionMode			= ProjectionModePerspective;
	rotationDrawMode		= LDrawGLDrawNormal;
	viewOrientation			= ViewOrientation3D;
	
	
	//Set up our OpenGL context. We need to base it on a shared context so that 
	// display-list names can be shared globally throughout the application.
	pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes: pixelAttributes];
	
	context = [[NSOpenGLContext alloc] initWithFormat:pixelFormat
										 shareContext:[LDrawApplication sharedOpenGLContext]];
	[self setOpenGLContext:context];
//	[context setView:self]; //documentation says to do this, but it generates an error. Weird.
	[[self openGLContext] makeCurrentContext];
		
	[self setPixelFormat:pixelFormat];
	[[self openGLContext] setValues: &swapInterval // prevent "tearing"
					   forParameter: NSOpenGLCPSwapInterval ];
			
	[pixelFormat release];
	
	return self;
	
}//end initWithCoder:


//========== prepareOpenGL =====================================================
//
// Purpose:		The context is all set up; this is where we prepare our OpenGL 
//				state.
//
//==============================================================================
- (void)prepareOpenGL
{
	glEnable(GL_DEPTH_TEST);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glEnable(GL_MULTISAMPLE); //antialiasing
	
	[self takeBackgroundColorFromUserDefaults]; //glClearColor()
	
	//
	// Define the lighting.
	//
	
	//Our light position is transformed by the modelview matrix. That means 
	// we need to have a standard model matrix loaded to get our light to 
	// land in the right place! But our modelview might have already been 
	// affected by someone calling -setViewOrientation:. So we restore the 
	// default here.
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	glRotatef(180,1,0,0); //convert to standard, upside-down LDraw orientation.
	
	// We are going to have two lights, one in a standard position (LIGHT0) and 
	// another pointing opposite to it (LIGHT1). The second light will 
	// illuminate any inverted normals or backwards polygons. 
	float position0[] = {0, -0.15, -1.0, 0};
	float position1[] = {0,  0.15,  1.0, 0};
	
	float lightModelAmbient[4]    = {0.6, 0.6, 0.6, 0.0};
	
	float light0Ambient[4]     = { 0.7, 0.7, 0.7, 1.0 };
	float light0Diffuse[4]     = { 1.0, 1.0, 1.0, 1.0 };
	float light0Specular[4]    = { 0.0, 0.0, 0.0, 1.0 };
	
	GLfloat ambient[4] = { 0.05, 0.05, 0.05, 1.0 };
//	GLfloat diffuse[4] = { 0.5, 0.5, 0.5, 1.0 };
	GLfloat specular[4]= { 0.0, 0.0, 0.0, 1.0 };
	GLfloat shininess  = 0;
	glMaterialfv( GL_FRONT_AND_BACK, GL_AMBIENT, ambient );
//	glMaterialfv( GL_FRONT_AND_BACK, GL_DIFFUSE, diffuse ); //don't bother; overridden by glColorMaterial
	glMaterialfv( GL_FRONT_AND_BACK, GL_SPECULAR, specular );
	glMaterialfv( GL_FRONT_AND_BACK, GL_SHININESS, &shininess );

	glColorMaterial(GL_FRONT_AND_BACK, GL_DIFFUSE);

	glShadeModel(GL_SMOOTH);
	glEnable(GL_NORMALIZE);
	glEnable(GL_COLOR_MATERIAL);
	

	glLightModeli( GL_LIGHT_MODEL_LOCAL_VIEWER,	GL_FALSE);
	glLightModeli( GL_LIGHT_MODEL_TWO_SIDE,		GL_TRUE );
	glLightModelfv(GL_LIGHT_MODEL_AMBIENT,		lightModelAmbient);
	
	//normal forward light
	glLightfv(GL_LIGHT0, GL_POSITION, position0);
	glLightfv(GL_LIGHT0, GL_AMBIENT,  light0Ambient);
	glLightfv(GL_LIGHT0, GL_DIFFUSE,  light0Diffuse);
	glLightfv(GL_LIGHT0, GL_SPECULAR, light0Specular);
	
	//opposing light to illuminate backward normals.
	glLightfv(GL_LIGHT1, GL_POSITION, position1);
	glLightfv(GL_LIGHT1, GL_AMBIENT,  light0Ambient);
	glLightfv(GL_LIGHT1, GL_DIFFUSE,  light0Diffuse);
	glLightfv(GL_LIGHT1, GL_SPECULAR, light0Specular);
	
	glEnable(GL_LIGHTING);
	glEnable(GL_LIGHT0);
	glEnable(GL_LIGHT1);
	
	
	//Now that the light is positioned where we want it, we can restore the 
	// correct viewing angle.
	[self setViewOrientation:self->viewOrientation];
	
}//end prepareOpenGL



#pragma mark -
#pragma mark DRAWING
#pragma mark -

//========== drawRect: =========================================================
//
// Purpose:		Draw the file into the view.
//
//==============================================================================
- (void) drawRect:(NSRect)rect
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	
	//We have the option of doing multithreaded drawing, so all the actual 
	// drawing code is in a thread-accessible method.
	
	//threading isn't working out well at all. So I have a threading preference, 
	// which will be OFF by default in version 1.4 at least.
	if([userDefaults boolForKey:@"UseThreads"] == YES)
		[NSThread detachNewThreadSelector:@selector(drawThreaded:) toTarget:self withObject:nil];
	else
		[self drawThreaded:nil];
		
}//end drawRect:


//========== drawThreaded: =====================================================
//
// Purpose:		My great attempt at organized chaos. This draw routine may be 
//				safely called off a thread!
//
//==============================================================================
- (void) drawThreaded:(id)sender
{
	NSAutoreleasePool	*pool				= [[NSAutoreleasePool alloc] init];
	NSDate				*startTime			= nil;
	unsigned			 options			= DRAW_NO_OPTIONS;
	NSTimeInterval		 drawTime			= 0;
	BOOL				 considerFastDraw	= NO;
	
	//mark another outstanding draw request, then get in line by requesting the 
	// mutex.
	@synchronized(self)
	{
		numberDrawRequests += 1;
	}
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		startTime	= [NSDate date];
	
		[[self openGLContext] makeCurrentContext];
		//any previous draw requests have now executed and let go of the mutex.
		// if we are the LAST draw in the queue, we draw. Otherwise, we drop 
		// ourselves, and defer to the last guy.
		if(numberDrawRequests == 1)
		{
			// We may need to simplify large models if we are spinning the model 
			// or doing part drag-and-drop. 
			considerFastDraw =		self->isTrackingDrag == YES
								||	(	[self->fileBeingDrawn respondsToSelector:@selector(draggingDirectives)]
									 &&	[(id)self->fileBeingDrawn draggingDirectives] != nil
									);
		#if DEBUG_DRAWING == 0
			if(considerFastDraw == YES && self->rotationDrawMode == LDrawGLDrawExtremelyFast)
			{
				options |= DRAW_BOUNDS_ONLY;
			}
		#endif //DEBUG_DRAWING
			
			//Load the model matrix to make sure we are applying the right stuff.
			glMatrixMode(GL_MODELVIEW);
			glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
			
			// Make lines look a little nicer; Max width 1.0; 0.5 at 100% zoom
			glLineWidth(MIN([self zoomPercentage]/100 * 0.5, 1.0));

			glColor4fv(glColor);
			
			// DRAW!
			[self->fileBeingDrawn draw:options parentColor:glColor];
			
			if([[self window] firstResponder] == self)
				[self drawFocusRing];
			
			//glFlush(); //implicit in -flushBuffer
			[[self openGLContext] flushBuffer];
		
			
			// If we just did a full draw, let's see if rotating needs to be 
			// done simply. 
			drawTime = -[startTime timeIntervalSinceNow];
			if(considerFastDraw == NO)
			{
				if( drawTime > SIMPLIFICATION_THRESHOLD )
					rotationDrawMode = LDrawGLDrawExtremelyFast;
				else
					rotationDrawMode = LDrawGLDrawNormal;
			}

		#if DEBUG_DRAWING
			NSLog(@"draw time: %f", drawTime);
		#endif //DEBUG_DRAWING
			
		}
		//else we just drop the draw.
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
	//cleanup
	@synchronized(self)
	{
		self->numberDrawRequests -= 1;
	}
	
	[pool release];
	
}//end drawRect:


//========== drawFocusRing =====================================================
//
// Purpose:		Draws a focus ring around the view, which indicates that this 
//				view is the first responder.
//
//==============================================================================
- (void) drawFocusRing
{
	NSRect	visibleRect = [self visibleRect];
	float	lineWidth	= 1.0;
	
	lineWidth /= [self zoomPercentage] / 100;
	
	//we just want to DRAW plain colored pixels.
	glDisable(GL_LIGHTING);
	
	glMatrixMode(GL_PROJECTION);
	glPushMatrix();
	{
		glLoadIdentity();
		gluOrtho2D( NSMinX(visibleRect), NSMaxX(visibleRect),
				    NSMinY(visibleRect), NSMaxY(visibleRect) );
				   
		glMatrixMode(GL_MODELVIEW);
		glPushMatrix();
		{
			//we indicate focus by drawing a series of framing lines.
			
			glLoadIdentity();
			
			glColor4ub(125, 151, 174, 255);
			[self strokeInsideRect:visibleRect
						 thickness:lineWidth];
			
			glColor4ub(137, 173, 204, 213);
			[self strokeInsideRect:NSInsetRect( visibleRect, 1 * lineWidth, 1 * lineWidth )
						 thickness:lineWidth];
			
			glColor4ub(161, 184, 204, 172);
			[self strokeInsideRect:NSInsetRect( visibleRect, 2 * lineWidth, 2 * lineWidth )
						 thickness:lineWidth];
			
			glColor4ub(184, 195, 204, 128);
			[self strokeInsideRect:NSInsetRect( visibleRect, 3 * lineWidth, 3 * lineWidth )
						 thickness:lineWidth];
		}
		glPopMatrix();
	}
	glMatrixMode(GL_PROJECTION);
	glPopMatrix();
	
	glEnable(GL_LIGHTING);

}//end drawFocusRing


//========== strokeInsideRect:thickness: =======================================
//
// Purpose:		Draws a line of the specified thickness on the inside edge of 
//				the rectangle.
//
//==============================================================================
- (void) strokeInsideRect:(NSRect)rect
				thickness:(float)borderWidth
{
	//draw like the wood of a picture frame: four trapezoids
	glBegin(GL_QUAD_STRIP);
	
	//lower left
	glVertex2f( NSMinX(rect),				NSMinY(rect)				);
	glVertex2f( NSMinX(rect) + borderWidth,	NSMinY(rect) + borderWidth	);
	
	//lower right
	glVertex2f( NSMaxX(rect),				NSMinY(rect)				);
	glVertex2f( NSMaxX(rect) - borderWidth,	NSMinY(rect) + borderWidth	);
	
	//upper right
	glVertex2f( NSMaxX(rect),				NSMaxY(rect)				);
	glVertex2f( NSMaxX(rect) - borderWidth,	NSMaxY(rect) - borderWidth	);
	
	//upper left
	glVertex2f( NSMinX(rect),				NSMaxY(rect)				);
	glVertex2f( NSMinX(rect) + borderWidth,	NSMaxY(rect) - borderWidth	);
	
	//lower left (finish last trapezoid)
	glVertex2f( NSMinX(rect),				NSMinY(rect)				);
	glVertex2f( NSMinX(rect) + borderWidth,	NSMinY(rect) + borderWidth	);
	
	glEnd();
	
}//end strokeInsideRect:thickness:


//========== isOpaque ==========================================================
//==============================================================================
//- (BOOL) isOpaque
//{
//	return NO;
//}

//========== isFlipped =========================================================
//
// Purpose:		This lets us appear in the upper-left of scroll views rather 
//				than the bottom. The view should draw just fine whether or not 
//				it is flipped, though.
//
//==============================================================================
- (BOOL) isFlipped
{
	return YES;
	
}//end isFlipped


#pragma mark -
#pragma mark ACCESSORS
#pragma mark -

//========== acceptsFirstResponder =============================================
//
// Purpose:		Allows us to pick up key events.
//
//==============================================================================
- (BOOL)acceptsFirstResponder
{
	return self->acceptsFirstResponder;
	
}//end acceptsFirstResponder


//========== centerPoint =======================================================
//
// Purpose:		Returns the point (in frame coordinates) which is currently 
//				at the center of the visible rectangle. This is useful for 
//				determining the point being viewed in the scroll view.
//
//==============================================================================
- (NSPoint) centerPoint
{
	NSRect visibleRect = [self visibleRect];
	return NSMakePoint( NSMidX(visibleRect), NSMidY(visibleRect) );
	
}//end centerPoint


//========== document ==========================================================
//
// Purpose:		Returns the document this view works in tandem with.
//
//==============================================================================
- (LDrawDocument *) document
{
	return self->document;
	
}//end document


//========== getInverseMatrix ==================================================
//
// Purpose:		Returns the inverse of the current modelview matrix. You can 
//				multiply points by this matrix to convert screen locations (or 
//				vectors) to model points.
//
// Note:		This function filters out the translation which is caused by 
//				"moving" the camera with gluLookAt. That allows us to continue 
//				working with the model as if it's positioned at the origin, 
//				which means that points we generate with this matrix will 
//				correspond to points in the LDraw model itself.
//
//==============================================================================
- (Matrix4) getInverseMatrix
{
	Matrix4	transformation	= [self getMatrix];
	Matrix4	inversed		= Matrix4Invert(transformation);
	
	return inversed;
	
}//end getInverseMatrix


//========== getMatrix =========================================================
//
// Purpose:		Returns the the current modelview matrix, basically.
//
// Note:		This function filters out the translation which is caused by 
//				"moving" the camera with gluLookAt. That allows us to continue 
//				working with the model as if it's positioned at the origin, 
//				which means that points we generate with this matrix will 
//				correspond to points in the LDraw model itself. 
//
//==============================================================================
- (Matrix4) getMatrix
{
	GLfloat	currentMatrix[16];
	Matrix4	transformation	= IdentityMatrix4;
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];

		glGetFloatv(GL_MODELVIEW_MATRIX, currentMatrix);
		transformation = Matrix4CreateFromGLMatrix4(currentMatrix); //convert to our utility library format
		
		// When using a perspective view, we must use gluLookAt to reposition 
		// the camera. That basically means translating the model. But all we're 
		// concerned about here is the *rotation*, so we'll zero out the 
		// translation components. 
		transformation.element[3][0] = 0;
		transformation.element[3][1] = 0; //translation is in the bottom row of the matrix.
		transformation.element[3][2] = 0;
		
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
	return transformation;
	
}//end getMatrix


//========== LDrawColor ========================================================
//
// Purpose:		Returns the LDraw color code of the receiver.
//
//==============================================================================
-(LDrawColorT) LDrawColor
{
	return self->color;
	
}//end color


//========== projectionMode ====================================================
//
// Purpose:		Returns the current projection mode (perspective or 
//				orthographic) used in the view.
//
//==============================================================================
- (ProjectionModeT) projectionMode
{
	return self->projectionMode;
	
}//end projectionMode


//========== viewingAngle ======================================================
//
// Purpose:		Returns the modelview rotation, in degrees.
//
// Notes:		These numbers do *not* include the fact that LDraw has an 
//				upside-down coordinate system. So if this method returns 
//				(0,0,0), that means "Front, looking right-side up." 
//				
//==============================================================================
- (Tuple3) viewingAngle
{
	Matrix4              transformation		= IdentityMatrix4;
	TransformComponents  components			= IdentityComponents;
	Tuple3				 degrees			= ZeroPoint3;
	
	transformation = [self getMatrix];
	transformation = Matrix4Rotate(transformation, V3Make(180, 0, 0)); // LDraw is upside-down
	Matrix4DecomposeTransformation(transformation, &components);
	degrees = components.rotate;
	
	degrees.x = degrees(degrees.x);
	degrees.y = degrees(degrees.y);
	degrees.z = degrees(degrees.z);
	
	return degrees;
	
}//end viewingAngle


//========== viewOrientation ===================================================
//
// Purpose:		Returns the current camera orientation for this view.
//
//==============================================================================
- (ViewOrientationT) viewOrientation
{
	return self->viewOrientation;
	
}//end viewOrientation


//========== zoomPercentage ====================================================
//
// Purpose:		Returns the percentage magnification being applied to the 
//				receiver. (200 means 2x magnification.) The scaling factor is
//				determined by the receiver's scroll view, not the GLView itself.
//				If the receiver is not contained within a scroll view, this 
//				method returns 100.
//
//==============================================================================
- (float) zoomPercentage
{
	NSScrollView	*scrollview		= [self enclosingScrollView];
	float			 zoomPercentage	= 0;
	
	if(scrollview != nil)
	{
		NSClipView	*clipview	= [scrollview contentView];
		NSRect		 clipFrame	= [clipview frame];
		NSRect		 clipBounds	= [clipview bounds];
		
		if(NSWidth(clipBounds) != 0)
			zoomPercentage = NSWidth(clipFrame) / NSWidth(clipBounds);
		else
			zoomPercentage = 1; //avoid division by zero
			
		zoomPercentage *= 100; //convert to percent
	}
	else
		zoomPercentage = 100;
	
	return zoomPercentage;
	
}//end zoomPercentage


#pragma mark -

//========== setAcceptsFirstResponder: =========================================
//
// Purpose:		Do we want to pick up key events?
//
//==============================================================================
- (void) setAcceptsFirstResponder:(BOOL)flag
{
	self->acceptsFirstResponder = flag;
}//end 


//========== setAutosaveName: ==================================================
//
// Purpose:		Sets the name under which this view saves its viewing 
//				configuration. Pass nil for no saving.
//
//==============================================================================
- (void) setAutosaveName:(NSString *)newName
{
	[newName retain];
	[self->autosaveName release];
	self->autosaveName = newName;
	
}//end setAutosaveName:


//========== setDelegate: ======================================================
//
// Purpose:		Sets the object that acts as the delegate for the receiver. 
//
// Notes:		This object acts in tandem two different "delegate" concepts: 
//				the delegate and the document. The delegate is responsible for 
//				more high-level, general activity, as described in the 
//				LDrawGLViewDelegate category. The document is an actual 
//				LDrawDocument, used for the nitty-gritty manipulation of the 
//				model this view supports. 
//
//==============================================================================
- (void) setDelegate:(id)object
{
	// weak link.
	self->delegate = object;
	
}//end setDelegate:


//========== setDragEndedInOurDocument: ========================================
//
// Purpose:		When a dragging operation we initiated ends outside the 
//				originating document, we need to know about it so that we can 
//				tell the document to completely delete the directives it started 
//				dragging. (They are merely hidden during the drag.) However, 
//				each document can be represented by multiple views, so it is 
//				insufficient to simply test whether the drag ended within this 
//				view. 
//
//				So, when a drag ends in any LDrawGLView, it inspects the 
//				dragging source to see if it represents the same document. If it 
//				does, it sends the source this message. If this message hasn't 
//				been received by the time the drag ends, this view will 
//				automatically instruct its document to purge the source 
//				directives, since the directives were actually dragged out of 
//				their document. 
//
//==============================================================================
- (void) setDragEndedInOurDocument:(BOOL)flag
{
	self->dragEndedInOurDocument = flag;
	
}//end setDragEndedInOurDocument:


//========== setLDrawColor: ====================================================
//
// Purpose:		Sets the base color for parts drawn by this view which have no 
//				color themselves.
//
//==============================================================================
-(void) setLDrawColor:(LDrawColorT)newColor
{
	self->color = newColor;
	
	//Look up the OpenGL color now so we don't have to whenever we draw.
	ColorLibrary	*colorLibrary	= [ColorLibrary sharedColorLibrary];
	LDrawColor		*colorObject	= nil;
	
	// Honestly, how often is the parent model color going to be a custom color? 
	// Never! 
//	if([self->fileBeingDrawn isKindOfClass:[LDrawFile class]] == YES)
//		colorLibrary = [[(LDrawFile*)fileBeingDrawn activeModel] colorLibrary];
//	else if([fileBeingDrawn isKindOfClass:[LDrawModel class]] == YES)
//		colorLibrary = [(LDrawModel*)fileBeingDrawn colorLibrary];

	colorObject = [colorLibrary colorForCode:newColor];
	[colorObject getColorRGBA:self->glColor]; 
	
}//end setColor


//========== LDrawDirective: ===================================================
//
// Purpose:		Sets the file being drawn in this view.
//
//				We also do other housekeeping here associated with tracking the 
//				model. We also automatically center the model in the view.
//
//==============================================================================
- (void) setLDrawDirective:(LDrawDirective *) newFile
{
	BOOL	firstDirective	= (self->fileBeingDrawn == nil);
	
	// We lock around the drawing context in case the current directive is being 
	// drawn right now. We certainly wouldn't want to release what we're 
	// drawing! 
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		NSRect frame = NSZeroRect;
		
		//Update our variable.
		[newFile retain];
		[self->fileBeingDrawn release];
		self->fileBeingDrawn = newFile;
		
		[[NSNotificationCenter defaultCenter] //force redisplay with glOrtho too.
				postNotificationName:NSViewFrameDidChangeNotification
							  object:self ];
		[self resetFrameSize];
		frame = [self frame]; //now that it's been changed above.
		if(firstDirective == YES)
			[self scrollCenterToPoint:NSMakePoint(NSWidth(frame)/2, NSHeight(frame)/2 )];
//		[self scrollCenterToPoint:scrollCenter];
		[self setNeedsDisplay:YES];

		//Register for important notifications.
		[[NSNotificationCenter defaultCenter] removeObserver:self name:LDrawFileDidChangeNotification object:nil];
		[[NSNotificationCenter defaultCenter] removeObserver:self name:LDrawFileActiveModelDidChangeNotification object:nil];
			
		[[NSNotificationCenter defaultCenter]
				addObserver:self
				   selector:@selector(displayNeedsUpdating:)
					   name:LDrawFileDidChangeNotification
					 object:self->fileBeingDrawn ];
		
		[[NSNotificationCenter defaultCenter]
				addObserver:self
				   selector:@selector(displayNeedsUpdating:)
					   name:LDrawFileActiveModelDidChangeNotification
					 object:self->fileBeingDrawn ];
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end setLDrawDirective:


//========== setProjectionMode: ================================================
//
// Purpose:		Sets the projection used when drawing the receiver:
//					- orthographic is like a Mercator map; it distorts deeper 
//									objects.
//					- perspective draws deeper objects toward a vanishing point; 
//									this is how humans see the world.
//
//==============================================================================
- (void) setProjectionMode:(ProjectionModeT) newProjectionMode
{
	self->projectionMode = newProjectionMode;
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];
		
		[self makeProjection];
		
		[self setNeedsDisplay:YES];
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
} //end setProjectionMode:


//========== setViewingAngle: ==================================================
//
// Purpose:		Sets the modelview rotation, in degrees. The angle is applied in 
//				x-y-z order. 
//
// Notes:		These numbers do *not* include the fact that LDraw has an 
//				upside-down coordinate system. So if this method returns 
//				(0,0,0), that means "Front, looking right-side up." 
//
//==============================================================================
- (void) setViewingAngle:(Tuple3)newAngle
{
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		//This method can get called from -prepareOpenGL, which is itself called 
		// from -makeCurrentContext. That's a recipe for infinite recursion. So, 
		// we only makeCurrentContext if we *need* to.
		if([NSOpenGLContext currentContext] != [self openGLContext])
			[[self openGLContext] makeCurrentContext];
		
		
		//Get the default angle.
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		
		//The camera distance was set for us by -resetFrameSize, so as to be able 
		// to see the entire model.
		gluLookAt( 0, 0, self->cameraDistance, //camera location
				  0,0,0, //look-at point
				  0, -1, 0 ); //LDraw is upside down.
		
		// Apply the requested angles, first x, then y, and lastly z.
		// But wait, you say! That is not the order in source code!
		// Well, that is because OpenGL's matrix order causes transformations to 
		// be applied backwards from the order in which they are specified.
		glRotatef( newAngle.z, 0, 0, 1);
		glRotatef( newAngle.y, 0, 1, 0);
		glRotatef( newAngle.x, 1, 0, 0);

		[self setNeedsDisplay:YES];
		
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end setViewingAngle:


//========== setViewOrientation: ===============================================
//
// Purpose:		Changes the camera position from which we view the model. 
//				i.e., ViewOrientationFront means we see the model head-on.
//
//==============================================================================
- (void) setViewOrientation:(ViewOrientationT)newOrientation
{
	Tuple3	newAngle	= [LDrawUtilities angleForViewOrientation:newOrientation];

	self->viewOrientation = newOrientation;
		
	// Apply the angle itself.
	[self setViewingAngle:newAngle];
	
}//end setViewOrientation:


//========== setZoomPercentage: ================================================
//
// Purpose:		Enlarges (or reduces) the magnification on this view. The center 
//				point of the original magnification remains the center point of 
//				the new magnification. Does absolutely nothing if this view 
//				isn't contained within a scroll view.
//
// Parameters:	newPercentage: new zoom; pass 100 for 100%, etc.
//
//==============================================================================
- (void) setZoomPercentage:(float) newPercentage
{
	NSScrollView *scrollView = [self enclosingScrollView];
	
	if(scrollView != nil)
	{
		NSClipView	*clipView		= [scrollView contentView];
		NSRect		 clipFrame		= [clipView frame];
		NSRect		 clipBounds		= [clipView bounds];
		NSPoint		 originalCenter	= [self centerPoint];
		
		newPercentage /= 100; //convert to a scale factor
		
		//Change the magnification level of the clip view, which has the effect 
		// of zooming us in and out.
		clipBounds.size.width	= NSWidth(clipFrame)  / newPercentage;
		clipBounds.size.height	= NSHeight(clipFrame) / newPercentage;
		[clipView setBounds:clipBounds]; //BREAKS AUTORESIZING. What to do?
		
		//Preserve the original view centerpoint. Note that the visible 
		// area has changed because we changed our zoom level.
		[self scrollCenterToPoint:originalCenter];
		[self resetFrameSize]; //ensures the canvas fills the whole scroll view
	}

}//end setZoomPercentage


#pragma mark -
#pragma mark ACTIONS
#pragma mark -

//========== viewOrientationSelected: ==========================================
//
// Purpose:		The user has chosen a new viewing angle from a menu.
//				sender is the menu item, whose tag is the viewing angle.
//
//==============================================================================
- (IBAction) viewOrientationSelected:(id)sender
{	
	ViewOrientationT newAngle = [sender tag];
	
	[self setViewOrientation:newAngle];
	
	//We treat 3D as a request for perspective, but any straight-on view can 
	// logically be expected to be displayed orthographically.
	if(newAngle == ViewOrientation3D)
		[self setProjectionMode:ProjectionModePerspective];
	else
		[self setProjectionMode:ProjectionModeOrthographic];
	
}//end viewOrientationSelected:


//========== zoomIn: ===========================================================
//
// Purpose:		Enlarge the scale of the current LDraw view.
//
//==============================================================================
- (IBAction) zoomIn:(id)sender
{
	float currentZoom	= [self zoomPercentage];
	float newZoom		= currentZoom * 2;
	
	[self setZoomPercentage:newZoom];
}//end 


//========== zoomOut: ==========================================================
//
// Purpose:		Shrink the scale of the current LDraw view.
//
//==============================================================================
- (IBAction) zoomOut:(id)sender
{
	float currentZoom	= [self zoomPercentage];
	float newZoom		= currentZoom / 2;
	
	[self setZoomPercentage:newZoom];
	
}//end zoomOut:


#pragma mark -
#pragma mark EVENTS
#pragma mark -

//========== becomeFirstResponder ==============================================
//
// Purpose:		This view is to become the first responder; we need to inform 
//				the rest of the file's views about this event.
//
//==============================================================================
- (BOOL) becomeFirstResponder
{
	BOOL success = [super becomeFirstResponder];
	
	if(success == YES)
	{
		if(self->delegate != nil && [self->delegate respondsToSelector:@selector(LDrawGLViewBecameFirstResponder:)])
			[self->delegate LDrawGLViewBecameFirstResponder:self];
		
		//need to draw the focus ring now
		[self setNeedsDisplay:YES];
	}
	
	return success;
}//end becomeFirstResponder


//========== resignFirstResponder ==============================================
//
// Purpose:		We are losing key status.
//
//==============================================================================
- (BOOL)resignFirstResponder
{
	BOOL success = [super resignFirstResponder];
	
	if(success == YES)
	{
		//need to lose the focus ring
		[self setNeedsDisplay:YES];
	}
	
	return success;
	
}//end resignFirstResponder


//========== resetCursor =======================================================
//
// Purpose:		Force a mouse-cursor update. We call this whenever a significant 
//				event occurs, such as a click or keypress.
//
//==============================================================================
- (void) resetCursor
{	
	//It seems -invalidateCursorRectsForView: only causes -resetCursorRects to 
	// get called if there is currently a cursor in force. So we oblige it.
	[self addCursorRect:[self visibleRect] cursor:[NSCursor arrowCursor]];
	
	[[self window] invalidateCursorRectsForView:self];	
	
}//end resetCursor


//========== resetCursorRects ==================================================
//
// Purpose:		Update the document cursor to reflect the current state of 
//				events.
//
//				To simplify, we set a single cursor for the entire view. 
//				Whenever the mouse enters our frame, the AppKit automatically 
//				takes care of adjusting the cursor. This method itself is called 
//				by the AppKit when necessary. We also coax it into happening 
//				more frequently by invalidating. See -resetCursor.
//
//==============================================================================
- (void) resetCursorRects
{
	[super resetCursorRects];
	
	NSRect		 visibleRect	= [self visibleRect];
	BOOL		 isClicked		= NO; /*[[NSApp currentEvent] type] == NSLeftMouseDown;*/ //not enough; overwhelmed by repeating key events
	NSCursor	*cursor			= nil;
	NSImage		*cursorImage	= nil;
	ToolModeT	 toolMode		= [ToolPalette toolMode];
	
	switch(toolMode)
	{
		case RotateSelectTool:
			//just use the standard arrow cursor.
			cursor = [NSCursor arrowCursor];
			break;
		
		case PanScrollTool:
			if(self->isTrackingDrag == YES || isClicked == YES)
				cursor = [NSCursor closedHandCursor];
			else
				cursor = [NSCursor openHandCursor];
			break;
			
		case SmoothZoomTool:
			if(self->isTrackingDrag == YES) {
				cursorImage = [NSImage imageNamed:@"ZoomCursor"];
				cursor = [[[NSCursor alloc] initWithImage:cursorImage
												  hotSpot:NSMakePoint(7, 10)] autorelease];
			}
			else
				cursor = [NSCursor crosshairCursor];
			break;
			
		case ZoomInTool:
			cursorImage = [NSImage imageNamed:@"ZoomInCursor"];
			cursor = [[[NSCursor alloc] initWithImage:cursorImage
											  hotSpot:NSMakePoint(7, 10)] autorelease];
			break;
			
		case ZoomOutTool:
			cursorImage = [NSImage imageNamed:@"ZoomOutCursor"];
			cursor = [[[NSCursor alloc] initWithImage:cursorImage
											  hotSpot:NSMakePoint(7, 10)] autorelease];
			break;
		
		case SpinTool:
			cursorImage = [NSImage imageNamed:@"Spin"];
			cursor = [[[NSCursor alloc] initWithImage:cursorImage
											  hotSpot:NSMakePoint(7, 10)] autorelease];
			break;
	}
	
	//update the cursor based on the tool mode.
	if(cursor != nil)
	{
		//Make this cursor active over the entire document.
		[self addCursorRect:visibleRect cursor:cursor];
		[cursor setOnMouseEntered:YES];
		
		//okay, something very weird is going on here. When the cursor is inside 
		// a view and THE PARTS BROWSER DRAWER IS OPEN, merely establishing a 
		// cursor rect isn't enough. It's somehow instantly erased when the 
		// LDrawGLView inside the drawer redoes its own cursor rects. Even 
		// calling -set on the cursor often has little more effect than a brief 
		// flicker. I don't know why this is happening, but this hack seems to 
		// fix it.
		if([self mouse:[self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil]
				inRect:[self visibleRect] ] ) //mouse is inside view.
		{
			//[cursor set]; //not enough.
			[cursor performSelector:@selector(set) withObject:nil afterDelay:0];
		}
		
	}
		
}//end resetCursorRects


//========== worksWhenModal ====================================================
//
// Purpose:		Due to buggy or at least undocumented behavior in Cocoa, this 
//				method must be implemented in order for objects of this class to 
//				be the target of menu actions when the instance resides in a 
//				modal dialog.
//
//				This was discovered experimentally by some enterprising soul on 
//				Cocoa-dev.
//
//==============================================================================
- (BOOL) worksWhenModal
{
	return YES;
	
}//end worksWhenModal


#pragma mark -
#pragma mark Keyboard

//========== keyDown: ==========================================================
//
// Purpose:		Certain key event have editorial significance. Like arrow keys, 
//				for instance. We need to assemble a sensible move request based 
//				on the arrow key pressed.
//
//==============================================================================
- (void)keyDown:(NSEvent *)theEvent
{
	NSString		*characters	= [theEvent charactersIgnoringModifiers];
	
//		[self interpretKeyEvents:[NSArray arrayWithObject:theEvent]];
	//We are circumventing the AppKit's key processing system here, because we 
	// may want to extend our keys to mean different things with different 
	// modifiers. It is easier to do that here than to pass it off to 
	// -interpretKeyEvent:. But beware of no-character keypresses like deadkeys.
	if([characters length] > 0)
	{
		unichar firstCharacter	= [characters characterAtIndex:0]; //the key pressed

		switch(firstCharacter)
		{
			//brick movements
			case NSUpArrowFunctionKey:
			case NSDownArrowFunctionKey:
			case NSLeftArrowFunctionKey:
			case NSRightArrowFunctionKey:
				[self nudgeKeyDown:theEvent];
				break;
			
			// handled by menu item
//			case NSDeleteCharacter: //regular delete character, apparently.
//			case NSDeleteFunctionKey: //forward delete--documented! My gosh!
//				[NSApp sendAction:@selector(delete:)
//							   to:nil //just send it somewhere!
//							 from:self];

			case ' ':
				// Swallow the spacebar, since it is a special tool-palette key. 
				// If we pass it up to super, it will cause a beep. 
				break;

			//viewing angle
			case '4':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationLeft];
				break;
			case '6':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationRight];
				break;
			case '2':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationBottom];
				break;
			case '8':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationTop];
				break;
			case '5':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationFront];
				break;
			case '7':
			case '9':
				[self setProjectionMode:ProjectionModeOrthographic];
				[self setViewOrientation:ViewOrientationBack];
				break;
			case '0':
				[self setProjectionMode:ProjectionModePerspective];
				[self setViewOrientation:ViewOrientation3D];
				break;
				
			default:
				[super keyDown:theEvent];
				break;
		}
		
	}

}//end keyDown:


//========== nudgeKeyDown: =====================================================
//
// Purpose:		We have received a keypress intended to move bricks. We need to 
//				figure out which direction to move them with respect to how the 
//				model is currently oriented.
//
//==============================================================================
- (void) nudgeKeyDown:(NSEvent *)theEvent
{
	NSString	*characters		= [theEvent characters];
	unichar		firstCharacter	= '\0';
	Vector3		xNudge			= ZeroPoint3;
	Vector3		yNudge			= ZeroPoint3;
	Vector3		zNudge			= ZeroPoint3;
	Vector3		actualNudge		= ZeroPoint3;
	BOOL		isZMovement		= NO;
	BOOL		isNudge			= NO;
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];
		
		if([characters length] > 0)
		{
			firstCharacter	= [characters characterAtIndex:0]; //the key pressed
			
			// find which model-coordinate directions our screen axes are best 
			// aligned with. 
			[self getModelAxesForViewX:&xNudge
									 Y:&yNudge
									 Z:&zNudge ];
				
			// By holding down the option key, we transcend the two-plane 
			// limitation presented by the arrow keys. Option-presses mean 
			// movement along the z-axis. Note that move "in" to the screen (up 
			// arrow, left arrow?) is a movement along the screen's negative 
			// z-axis. 
			isZMovement	= ([theEvent modifierFlags] & NSAlternateKeyMask) != 0;
			isNudge		= NO;
			
			//now we must select which axis we actually are nudging on.
			switch(firstCharacter)
			{
				case NSUpArrowFunctionKey:
				
					if(isZMovement == YES)
					{
						//into the screen (-z)
						actualNudge = V3Negate(zNudge);
					}
					else
						actualNudge = yNudge;
					isNudge = YES;
					break;
					
				case NSDownArrowFunctionKey:
				
					if(isZMovement == YES)
						actualNudge = zNudge;
					else
					{
						actualNudge = V3Negate(yNudge);
					}
					isNudge = YES;
					break;
					
				case NSLeftArrowFunctionKey:
				
					if(isZMovement == YES)
					{
						//this is iffy at best
						actualNudge = V3Negate(zNudge);
					}
					else
					{
						actualNudge = V3Negate(xNudge);
					}
					isNudge = YES;
					break;
					
				case NSRightArrowFunctionKey:
				
					if(isZMovement == YES)
						actualNudge = zNudge;
					else
						actualNudge = xNudge;
					isNudge = YES;
					break;
					
				default:
					break;
			}
			
			//Pass the nudge along to the document, which is the one actually in 
			// charge of manipulating the data.
			if(isNudge == YES)
			{
				if(document != nil)
					[document nudgeSelectionBy:actualNudge]; 
			}
		}
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end nudgeKeyDown:


#pragma mark -
#pragma mark Mouse

//========== mouseDown: ========================================================
//
// Purpose:		We received a mouseDown before a mouseDragged. Handy thought.
//
//==============================================================================
- (void) mouseDown:(NSEvent *)theEvent
{
	NSUserDefaults		*userDefaults		= [NSUserDefaults standardUserDefaults];
	MouseDragBehaviorT	 draggingBehavior	= [userDefaults integerForKey:MOUSE_DRAGGING_BEHAVIOR_KEY];
	ToolModeT			 toolMode			= [ToolPalette toolMode];
	
	// Reset event tracking flags.
	self->isTrackingDrag	= NO;
	self->didPartSelection	= NO;
	
	[self resetCursor];
	
	if(toolMode == SmoothZoomTool)
		[self mouseCenterClick:theEvent];
		
	else if(toolMode == RotateSelectTool)
	{
		switch(draggingBehavior)
		{
			case MouseDraggingOff:
				// do nothing
				break;
			
			case MouseDraggingBeginAfterDelay:
				[self cancelClickAndHoldTimer]; // just in case
				
				// Try waiting for a click-and-hold; that means "begin 
				// drag-and-drop" 
				self->mouseDownTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
																		target:self
																	  selector:@selector(clickAndHoldTimerFired:)
																	  userInfo:theEvent
																	   repeats:NO ];
				break;			
			
			case MouseDraggingBeginImmediately:
				[self mousePartSelection:theEvent];
				break;
			
			case MouseDraggingImmediatelyInOrthoNeverInPerspective:
				if([self projectionMode] == ProjectionModeOrthographic)
				{
					[self mousePartSelection:theEvent];
				}
				break;
		}
	
	}
	
}//end mouseDown:


//========== mouseDragged: =====================================================
//
// Purpose:		The user has dragged the mouse after clicking it.
//
//==============================================================================
- (void)mouseDragged:(NSEvent *)theEvent
{
	NSUserDefaults		*userDefaults		= [NSUserDefaults standardUserDefaults];
	MouseDragBehaviorT	 draggingBehavior	= [userDefaults integerForKey:MOUSE_DRAGGING_BEHAVIOR_KEY];
	ToolModeT			 toolMode			= [ToolPalette toolMode];

	self->isTrackingDrag = YES;
	[self resetCursor];

	
	//What to do?
	
	if(toolMode == PanScrollTool)
		[self panDragged:theEvent];
	
	if(toolMode == SpinTool)
		[self rotationDragged:theEvent];
	
	else if(toolMode == SmoothZoomTool)
		[self zoomDragged:theEvent];
	
	else if(toolMode == RotateSelectTool)
	{
		switch(draggingBehavior)
		{
			case MouseDraggingOff:
				[self rotationDragged:theEvent];
				break;
				
			case MouseDraggingBeginAfterDelay:
				// If the delay has elapsed, begin drag-and-drop. Otherwise, 
				// just spin the model. 
				if(self->canBeginDragAndDrop == YES)
					[self dragAndDropDragged:theEvent];
				else			
					[self rotationDragged:theEvent];
				break;			
				
			case MouseDraggingBeginImmediately:
				[self dragAndDropDragged:theEvent];
				break;
				
			case MouseDraggingImmediatelyInOrthoNeverInPerspective:
				if([self projectionMode] == ProjectionModePerspective)
					[self rotationDragged:theEvent];
				else
					[self dragAndDropDragged:theEvent];
				break;
		}
	}
	
	// Don't wait for drag-and-drop anymore. We need to do this after we process 
	// the drag, because it clears the can-drag flag. 
	[self cancelClickAndHoldTimer];
	
}//end mouseDragged


//========== mouseUp: ==========================================================
//
// Purpose:		The mouse has been released. Figure out exactly what that means 
//				in the wider context of what the mouse did before now.
//
//==============================================================================
- (void) mouseUp:(NSEvent *)theEvent
{
	ToolModeT			 toolMode			= [ToolPalette toolMode];

	[self cancelClickAndHoldTimer];

	if( toolMode == RotateSelectTool )
	{
		//We only want to select a part if this was NOT part of a mouseDrag event.
		// Otherwise, the selection should remain intact.
		if(self->isTrackingDrag == NO && self->didPartSelection == NO)
			[self mousePartSelection:theEvent];
	}
	
	else if(	toolMode == ZoomInTool
			||	toolMode == ZoomOutTool )
		[self mouseZoomClick:theEvent];
	
	//Redraw from our dragging operations, if necessary.
	if(	self->isTrackingDrag == YES && rotationDrawMode == LDrawGLDrawExtremelyFast )
		[self setNeedsDisplay:YES];
		
	self->isTrackingDrag = NO; //not anymore.
	[self resetCursor];
	
}//end mouseUp:


//========== menuForEvent: =====================================================
//
// Purpose:		Customize the contextual menu for the given mouse-down event. 
//
//				Calls to this method are filtered by the events the system 
//				considers acceptible for invoking a contextual menu; namely, 
//				right-clicks and control-clicks. 
//
//==============================================================================
- (NSMenu *) menuForEvent:(NSEvent *)theEvent
{
	int modifiers = [theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask;
	
	// Only display contextual menus for pure control- or right-clicks. By 
	// default, the system permits control+<any other modifiers> to trigger 
	// contextual menus. We want to use control/modifier combos to activate 
	// other mouse tools, so we filter out those events. 
	if(		modifiers == NSControlKeyMask // and nothing eles!
	   ||	[theEvent type] == NSRightMouseDown )
		return [self menu];
	else
		return nil;
		
}//end menuForEvent:


#pragma mark - Dragging

//========== dragAndDropDragged: ===============================================
//
// Purpose:		This is a special mouseDragged which means to begin a Mac OS 
//				drag-and-drop operation. The originating drag dies here; once we 
//				start drag-and-drop, the OS machinery takes over and we don't 
//				track mouseDraggeds anymore. 
//
//==============================================================================
- (void) dragAndDropDragged:(NSEvent *)theEvent
{
	NSPasteboard			*pasteboard			= nil;
	NSPoint					 imageLocation		= NSZeroPoint;
	BOOL					 beginCopy			= NO;
	BOOL					 okayToDrag			= NO;
	NSPoint					 offset				= NSZeroPoint;
	NSArray					*archivedDirectives	= nil;
	NSData					*data				= nil;
	LDrawDrawableElement	*firstDirective		= nil;
	NSPoint					 viewPoint			= [self convertPoint:[theEvent locationInWindow] fromView:nil];
	Point3					 modelPoint			= ZeroPoint3;
	Point3					 firstPosition		= ZeroPoint3;
	Vector3					 displacement		= ZeroPoint3;
	NSImage					*dragImage			= nil;

	if(		self->delegate != nil
	   &&	[self->delegate respondsToSelector:@selector(LDrawGLView:writeDirectivesToPasteboard:asCopy:)] )
	{
		pasteboard		= [NSPasteboard pasteboardWithName:NSDragPboard];
		beginCopy		= ([theEvent modifierFlags] & NSAlternateKeyMask) != 0;
	
		okayToDrag		= [self->delegate LDrawGLView:self writeDirectivesToPasteboard:pasteboard asCopy:beginCopy];
		
		if(okayToDrag == YES)
		{
			//---------- Find drag displacement --------------------------------
			//
			// When a drag enters a view, the first part's position is normally 
			// set to the model point under the mouse. But that is incorrect 
			// behavior when entering the originating view. The user almost 
			// certainly did not click the mouse at the exact center of part 0, 
			// but nevertheless he does not expect part 0 of his selection to 
			// suddenly become centered under the mouse after dragging only one 
			// pixel.
			//
			// Instead we record the offset of his actual originating 
			// click against the position of part 0. Now when this drag reenters 
			// its originating view, its position will be adjusted by that 
			// offset. Everything will come out looking right. 
			//
			archivedDirectives	= [pasteboard propertyListForType:LDrawDraggingPboardType];
			data				= [archivedDirectives objectAtIndex:0];
			firstDirective		= [NSKeyedUnarchiver unarchiveObjectWithData:data];
			firstPosition		= [firstDirective position];
			modelPoint			= [self modelPointForPoint:viewPoint depthReferencePoint:firstPosition];
			displacement		= V3Sub(modelPoint, firstPosition);
			
			// write displacement to private pasteboard.
			[pasteboard addTypes:[NSArray arrayWithObject:LDrawDraggingInitialOffsetPboardType] owner:self];
			[pasteboard setData:[NSData dataWithBytes:&displacement length:sizeof(Vector3)]
						forType:LDrawDraggingInitialOffsetPboardType];
			
			
			//---------- Reset event tracking flags ----------------------------

			// reset drop destination flag.
			[self setDragEndedInOurDocument:NO];
			
			// Once we give control to drag-and-drop, we no longer receive 
			// mouseDragged events. 
			self->isTrackingDrag = NO;
			
			
			//---------- Start drag-and-drop ----------------------------------

			imageLocation	= [self convertPoint:[theEvent locationInWindow] fromView:nil];
			dragImage		= [LDrawUtilities dragImageWithOffset:&offset];
			
			// Offset the image location so that the drag image appears to the 
			// lower-right of the arrow like a dragging badge. 
			imageLocation.x +=  offset.x;
			imageLocation.y += -offset.y; // Invert y because this view is flipped.
			
			// Initiate Drag.
			[self dragImage:dragImage
						 at:imageLocation
					 offset:NSZeroSize
					  event:theEvent
				 pasteboard:pasteboard
					 source:self
				  slideBack:NO ];
			
			// **** -dragImage: BLOCKS until drag is complete. ****
		}
	}

}//end dragAndDropDragged:


//========== panDrag: ==========================================================
//
// Purpose:		Scroll the view as the mouse is dragged across it. This is 
//				triggered by holding down the shift key and dragging
//				(see -mouseDragged:).
//
//==============================================================================
- (void) panDragged:(NSEvent *)theEvent
{
	NSRect	visibleRect	= [self visibleRect];
	float	scaleFactor	= [self zoomPercentage] / 100;
	
	//scroll the opposite direction of pull.
	visibleRect.origin.x -= [theEvent deltaX] / scaleFactor;
	visibleRect.origin.y -= [theEvent deltaY] / scaleFactor;
	
	[self scrollRectToVisible:visibleRect];

}//end panDragged:


//========== rotationDragged: ==================================================
//
// Purpose:		Tis time to rotate the object!
//
//				We need to translate horizontal and vertical 2-dimensional mouse 
//				drags into 3-dimensional rotations.
//
//		 +---------------------------------+       ///  /- -\ \\\   (This thing is a sphere.)
//		 |             y /|\               |      /     /   \    \				.
//		 |                |                |    //      /   \     \\			.
//		 |                |vertical        |    |   /--+-----+-\   |
//		 |                |motion (around x)   |///    |     |   \\\|
//		 |                |              x |   |       |     |      |
//		 |<---------------+--------------->|   |       |     |      |
//		 |                |     horizontal |   |\\\    |     |   ///|
//		 |                |     motion     |    |   \--+-----+-/   |
//		 |                |    (around y)  |    \\     |     |    //
//		 |                |                |      \     \   /    /
//		 |               \|/               |       \\\  \   / ///
//		 +---------------------------------+          --------
//
//				But 2D motion is not 3D motion! We can't just say that 
//				horizontal drag = rotation around y (up) axis. Why? Because the 
//				y-axis may be laying horizontally due to the rotation!
//
//				The trick is to convert the y-axis *on the projection screen* 
//				back to a *vector in the model*. Then we can just call glRotate 
//				around that vector. The result that the model is rotated in the 
//				direction we dragged, no matter what its orientation!
//
//				Last Note: A horizontal drag from left-to-right is a 
//					counterclockwise rotation around the projection's y axis.
//					This means a positive number of degrees caused by a positive 
//					mouse displacement.
//					But, a vertical drag from bottom-to-top is a clockwise 
//					rotation around the projection's x-axis. That means a 
//					negative number of degrees cause by a positive mouse 
//					displacement. That means we must multiply our x-rotation by 
//					-1 in order to make it go the right direction.
//
//==============================================================================
- (void)rotationDragged:(NSEvent *)theEvent
{
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		//Since there are multiple OpenGL rendering areas on the screen, we must 
		// explicitly indicate that we are drawing into ourself. Weird yes, but 
		// horrible things happen without this call.
		[[self openGLContext] makeCurrentContext];
		
		float	deltaX			=   [theEvent deltaX];
		float	deltaY			= - [theEvent deltaY]; //Apple's delta is backwards, for some reason.
		float	viewWidth		= NSWidth([self frame]);
		float	viewHeight		= NSHeight([self frame]);
		
		// Get the percentage of the window we have swept over. Since half the 
		// window represents 180 degrees of rotation, we will eventually 
		// multiply this percentage by 180 to figure out how much to rotate. 
		float	percentDragX	= deltaX / viewWidth;
		float	percentDragY	= deltaY / viewHeight;
		
		//Remember, dragging on y means rotating about x.
		float	rotationAboutY	= + ( percentDragX * 180 );
		float	rotationAboutX	= - ( percentDragY * 180 ); //multiply by -1,
					// as we need to convert our drag into a proper rotation 
					// direction. See notes in function header.
		
		//Get the current transformation matrix. By using its inverse, we can 
		// convert projection-coordinates back to the model coordinates they 
		// are displaying.
		Matrix4 inversed = [self getInverseMatrix];
		
		// Now we will convert what appears to be the vertical and horizontal 
		// axes into the actual model vectors they represent. 
		Vector4 vectorX = {1,0,0,1}; //unit vector i along x-axis.
		Vector4 vectorY = {0,1,0,1}; //unit vector j along y-axis.
		Vector4 transformedVectorX;
		Vector4 transformedVectorY;
		
		// We do this conversion from screen to model coordinates by multiplying 
		// our screen points by the modelview matrix inverse. That has the 
		// effect of "undoing" the model matrix on the screen point, leaving us 
		// a model point. 
		transformedVectorX = V4MulPointByMatrix(vectorX, inversed);
		transformedVectorY = V4MulPointByMatrix(vectorY, inversed);
		
		if(self->viewOrientation != ViewOrientation3D)
		{
			[self setProjectionMode:ProjectionModePerspective];
			self->viewOrientation = ViewOrientation3D;
		}
		
		//Now rotate the model around the visual "up" and "down" directions.
		glMatrixMode(GL_MODELVIEW);
		glRotatef( rotationAboutY, transformedVectorY.x, transformedVectorY.y, transformedVectorY.z);
		glRotatef( rotationAboutX, transformedVectorX.x, transformedVectorX.y, transformedVectorX.z);
		
		[self setNeedsDisplay: YES];
		
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end rotationDragged


//========== zoomDragged: ======================================================
//
// Purpose:		Drag up means zoom in, drag down means zoom out. 1 px = 1 %.
//
//==============================================================================
- (void) zoomDragged:(NSEvent *)theEvent
{
	float zoomChange	= -[theEvent deltaY];
	float currentZoom	= [self zoomPercentage];
	
	//Negative means down
	[self setZoomPercentage:currentZoom + zoomChange];
	
}//end zoomDragged:


#pragma mark - Clicking

//========== mouseCenterClick: =================================================
//
// Purpose:		We have received a mouseDown event which is intended to center 
//				our view on the point clicked.
//
//==============================================================================
- (void) mouseCenterClick:(NSEvent*)theEvent
{	
	NSPoint newCenter = [self convertPoint:[theEvent locationInWindow]
								  fromView:nil ];
	
	[self scrollCenterToPoint:newCenter];
}//end mouseCenterClick:


//========== mousePartSelection: ===============================================
//
// Purpose:		Time to see if we should select something in the model.
//				OpenGL has a selection mode in which it records the name-tag 
//				for anything that renders within the viewing area. We utilize 
//				this feature to find out what part was clicked on.
//
// Notes:		This method is optimized to do an iterative search, first with a
//				low-resolution draw, then on a high-resolution pass. It's about 
//				six times faster than just drawing the whole model.
//
//==============================================================================
- (void)mousePartSelection:(NSEvent *)theEvent
{
	NSArray			*fastDrawParts		= nil;
	NSArray			*fineDrawParts		= nil;
	LDrawDirective	*clickedDirective	= nil;
	BOOL			 extendSelection	= NO;
	
	// Per the AHIG, both command and shift are used for multiple selection. In 
	// Bricksmith, there is no difference between contiguous and non-contiguous 
	// selection, so both keys do the same thing. 
	// -- We desperately need simple modifiers for rotating the view. Otherwise, 
	// I doubt people would discover it. 
	extendSelection =	([theEvent modifierFlags] & NSShiftKeyMask) != 0;
//					 ||	([theEvent modifierFlags] & NSCommandKeyMask) != 0;
	
	// Only try to select if we are actually drawing something, and can actually 
	// select it. 
	if(		self->fileBeingDrawn != nil
	   &&	[self->delegate respondsToSelector:@selector(LDrawGLView:wantsToSelectDirective:byExtendingSelection:)] )
	{
		//first do hit-testing on nothing but the bounding boxes; that is very fast 
		// and likely eliminates a lot of parts.
		fastDrawParts	= [self getDirectivesUnderMouse:theEvent
										amongDirectives:[NSArray arrayWithObject:self->fileBeingDrawn]
											   fastDraw:YES];
		
		//now do a full draw for testing on the most likely candidates
		fineDrawParts	= [self getDirectivesUnderMouse:theEvent
										amongDirectives:fastDrawParts
											   fastDraw:NO];
		
		if([fineDrawParts count] > 0)
			clickedDirective = [fineDrawParts objectAtIndex:0];
		
		// If the clicked part is already selected, calling this method will 
		// deselect it. Generally, we want to leave the current selection intact 
		// (so we can drag it, maybe). The exception is multiple-selection mode, 
		// which means we actually *want* to deselect it. 
		if(		[clickedDirective isSelected] == NO
		   ||	(	[clickedDirective isSelected] == YES // allow deselection
				 && extendSelection == YES
				)
		  )
		{
			//Notify our delegate about this momentous event.
			// It's okay to send nil; that means "deselect."
			// We want to add this to the current selection if the shift key is down.
			[self->delegate LDrawGLView:self
				 wantsToSelectDirective:clickedDirective
				   byExtendingSelection:extendSelection ];
		}
	}

	self->didPartSelection = YES;
	
}//end mousePartSelection:


//========== mouseZoomClick: ===================================================
//
// Purpose:		Depending on the tool mode, we want to zoom in or out. We also 
//				want to center the view on whatever we clicked on.
//
//==============================================================================
- (void) mouseZoomClick:(NSEvent*)theEvent
{
	ToolModeT	toolMode	= [ToolPalette toolMode];
	float		currentZoom	= [self zoomPercentage];
	float		newZoom		= 0;
	NSPoint		newCenter	= [self convertPoint:[theEvent locationInWindow]
										fromView:nil ];

	if(	toolMode == ZoomInTool )
		newZoom = currentZoom * 2;
	
	else if( toolMode == ZoomOutTool )
		newZoom = currentZoom / 2;
		
	[self setZoomPercentage:newZoom];
	[self scrollCenterToPoint:newCenter];
	
}//end mouseZoomClick:


#pragma mark -

//========== cancelClickAndHoldTimer ===========================================
//
// Purpose:		Something has happened which interrupts a click-and-hold, such 
//				as maybe a mouseUp. 
//
//==============================================================================
- (void) cancelClickAndHoldTimer
{
	if(self->mouseDownTimer != nil)
	{
		[self->mouseDownTimer invalidate];
		self->mouseDownTimer = nil;
	}
	self->canBeginDragAndDrop	= NO;
	
}//end cancelClickAndHoldTimer


//========== clickAndHoldTimerFired: ===========================================
//
// Purpose:		If we got here, it means the user has successfully executed a 
//				click-and-hold, which means that the mouse button was clicked, 
//				held down, and not moved for a certain period of time. 
//
//				We use this action to initiate a drag-and-drop.
//
//==============================================================================
- (void) clickAndHoldTimerFired:(NSTimer*)theTimer
{
	NSEvent	*clickEvent	= [theTimer userInfo];

	// the timer has expired; nil it out so nobody tries to message it after 
	// it's been released. 
	self->mouseDownTimer = nil;
	
	[self mousePartSelection:clickEvent];
	
	// Actual Mac Drag-and-Drop can only be initiated upon a mouseDown or 
	// mouseDragged. So we wait until one of those actually happens to do 
	// anything, and set this flag to tell us what to do when the moment comes.
	self->canBeginDragAndDrop	= YES;
	
}//end clickAndHoldTimerFired:


#pragma mark -
#pragma mark DRAG AND DROP
#pragma mark -

//========== draggingEntered: ==================================================
//
// Purpose:		A drag-and-drop part operation entered this view. We need to 
//			    initiate interactive dragging. 
//
//==============================================================================
- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)info
{
	NSPasteboard			*pasteboard			= [info draggingPasteboard];
	id						 sourceView			= [info draggingSource];
	NSDragOperation			 dragOperation		= NSDragOperationNone;
	NSArray					*archivedDirectives	= nil;
	NSMutableArray			*directives			= nil;
	LDrawDrawableElement	*firstDirective		= nil;
	LDrawPart				*newPart			= nil;
	NSData					*data				= nil;
	id						 currentObject		= nil;
	int						 directiveCount		= 0;
	int						 counter			= 0;
	NSPoint					 dragPointInWindow	= [info draggingLocation];
	TransformComponents		 partTransform		= IdentityComponents;
	Point3					 modelReferencePoint= ZeroPoint3;
	NSData					*vectorOffsetData	= nil;
	
	// local drag?
	if(sourceView == self)
		dragOperation = NSDragOperationMove;
	else
		dragOperation = NSDragOperationCopy;
	
	
	//---------- unarchive the directives --------------------------------------
	
	archivedDirectives	= [pasteboard propertyListForType:LDrawDraggingPboardType];
	directiveCount		= [archivedDirectives count];
	directives			= [NSMutableArray arrayWithCapacity:directiveCount];
	
	for(counter = 0; counter < directiveCount; counter++)
	{
		data			= [archivedDirectives objectAtIndex:counter];
		currentObject	= [NSKeyedUnarchiver unarchiveObjectWithData:data];
		
		// while a part is dragged, it is drawn selected
		[currentObject setSelected:YES];
		
		[directives addObject:currentObject];
	}
	firstDirective = [directives objectAtIndex:0];
	
	
	//---------- Initialize New Part? ------------------------------------------
	
	if([[pasteboard propertyListForType:LDrawDraggingIsUninitializedPboardType] boolValue] == YES)
	{
		// Uninitialized elements are always new parts from the part browser.
		newPart = [directives objectAtIndex:0];
	
		// Ask the delegate roughly where it wants us to be.
		// We get a full transform here so that when we drag in new parts, they 
		// will be rotated the same as whatever part we were using last. 
		if([self->delegate respondsToSelector:@selector(LDrawGLViewPreferredPartTransform:)])
		{
			partTransform = [self->delegate LDrawGLViewPreferredPartTransform:self];
			[newPart setTransformComponents:partTransform];
		}
	}
	
	
	//---------- Find Location -------------------------------------------------
	// We need to map our 2-D mouse coordinate into a point in the model's 3-D 
	// space.
	
	modelReferencePoint	= [firstDirective position];
	
	// Apply the initial offset.
	// This is the difference between the position of part 0 and the actual 
	// clicked point. We do this so that the point you clicked always remains 
	// directly under the mouse.
	//
	// Only applicable if dragging into the source 
	// view. Other views may have different orientations. We might be able to 
	// remove that requirement by zeroing the inapplicable compont. 
	if(sourceView == self)
	{
		vectorOffsetData = [pasteboard dataForType:LDrawDraggingInitialOffsetPboardType];
		[vectorOffsetData getBytes:&self->draggingOffset length:sizeof(Vector3)];
		
		modelReferencePoint = V3Add(modelReferencePoint, self->draggingOffset);
	}
	// For constrained dragging, we care only about the initial, unmodified 
	// postion. 
	self->initialDragLocation = modelReferencePoint;
	
	// Move the parts
	[self updateDirectives:directives
		  withDragPosition:dragPointInWindow
	   depthReferencePoint:modelReferencePoint
			 constrainAxis:NO];
	
	// The drag has begun!
	if([self->fileBeingDrawn respondsToSelector:@selector(setDraggingDirectives:)])
	{
		[(id)self->fileBeingDrawn setDraggingDirectives:directives];
		
		[[NSNotificationCenter defaultCenter]
					postNotificationName:LDrawDirectiveDidChangeNotification
								  object:self->fileBeingDrawn ];
	}
	
	return dragOperation;
	
}//end draggingEntered:


//========== draggingUpdated: ==================================================
//
// Purpose:		As the mouse moves around the screen, we need to update the 
//			    location of the parts being drug. 
//
//==============================================================================
- (NSDragOperation) draggingUpdated:(id <NSDraggingInfo>)info
{
	NSArray					*directives				= nil;
	LDrawDrawableElement	*firstDirective			= nil;
	id						 sourceView				= [info draggingSource];
	NSPoint					 dragPointInWindow		= [info draggingLocation];
	Point3					 modelReferencePoint	= ZeroPoint3;
	BOOL					 constrainDragAxis		= NO;
	BOOL					 moved					= NO;
	NSDragOperation			 dragOperation			= NSDragOperationNone;
	
	// local drag?
	if(sourceView == self)
		dragOperation = NSDragOperationMove;
	else
		dragOperation = NSDragOperationCopy;
	
	// Update the dragged parts.
	if([self->fileBeingDrawn respondsToSelector:@selector(draggingDirectives)])
	{
		directives			= [(id)self->fileBeingDrawn draggingDirectives];
		firstDirective		= [directives objectAtIndex:0];
		modelReferencePoint	= [firstDirective position];
		
		// Apply the offset if appropriate
		if(sourceView == self)
			modelReferencePoint = V3Add(modelReferencePoint, self->draggingOffset);
		
		// If the shift key is down, only allow dragging along one axis as is 
		// conventional in graphics programs. Cocoa gives us no way to get at 
		// the event that initiated this call, so we have to hack. 
		constrainDragAxis = ([[NSApp currentEvent] modifierFlags] & NSShiftKeyMask) != 0;
		
		// Update with new position
		moved	= [self updateDirectives:directives
					  withDragPosition:dragPointInWindow
				   depthReferencePoint:modelReferencePoint
						 constrainAxis:constrainDragAxis];
		
		if(moved == YES)
		{
			[[NSNotificationCenter defaultCenter]
							postNotificationName:LDrawDirectiveDidChangeNotification
										  object:self->fileBeingDrawn ];
		}
	}
	
	return dragOperation;
	
}//end draggingUpdated:


//========== draggingExited: ===================================================
//
// Purpose:		The drag has left the building.
//
//==============================================================================
- (void)draggingExited:(id <NSDraggingInfo>)sender
{
	[self concludeDragOperation:sender];

}//end draggingExited:


//========== performDragOperation: =============================================
//
// Purpose:		Okay, we're done. It's time to import the directives which are 
//			    on the dragging pasteboard into the model itself. 
//
// Notes:		Fortunately, we have already unpacked all the directives when 
//			    dragging first entered the view, so all we need to do is move 
//			    those directives from the file's drag list and dump them in the 
//			    main model. 
//
//==============================================================================
- (BOOL) performDragOperation:(id <NSDraggingInfo>)sender
{
	NSArray			*directives		= nil;
	LDrawDocument	*senderDocument	= nil;
	
	if([self->fileBeingDrawn respondsToSelector:@selector(draggingDirectives)])
	{
		directives = [(id)self->fileBeingDrawn draggingDirectives];
		
		if([self->delegate respondsToSelector:@selector(LDrawGLView:acceptDrop:directives:)])
		   [self->delegate LDrawGLView:self acceptDrop:sender directives:directives];
	}
	
	if([[sender draggingSource] respondsToSelector:@selector(document)])
	{
		senderDocument = [[sender draggingSource] document];
		if(senderDocument == self->document)
			[[sender draggingSource] setDragEndedInOurDocument:YES];
	}
	
	return YES;
	
}//end performDragOperation:


//========== concludeDragOperation: ============================================
//
// Purpose:		The drag is accepted, imported, and over with. Clean up the 
//			    display to remove the dragging directives from the display.
//
//==============================================================================
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender
{
	if([self->fileBeingDrawn respondsToSelector:@selector(setDraggingDirectives:)])
	{
		[(id)self->fileBeingDrawn setDraggingDirectives:nil];
		
		[[NSNotificationCenter defaultCenter]
						postNotificationName:LDrawDirectiveDidChangeNotification
									  object:self->fileBeingDrawn ];
	}
}//end concludeDragOperation:


//========== draggedImage:endedAt:operation: ===================================
//
// Purpose:		The drag ended somewhere. Maybe it was here, maybe it wasn't.
//
//				If it ended in some other file, we need to instruct our delegate 
//				to actually delete the dragged directives. When they are written 
//				to the pasteboard, they are only hidden so that they can be 
//				modified when the drag ends. 
//
//==============================================================================
- (void)draggedImage:(NSImage *)anImage
			 endedAt:(NSPoint)aPoint
		   operation:(NSDragOperation)operation
{
	// If the drag didn't wind up in one of the GL views belonging to this 
	// document, then we need to delete the part's ghost from our model.
	if(self->dragEndedInOurDocument == NO)
	{
		if([self->delegate respondsToSelector:@selector(LDrawGLViewPartsWereDraggedIntoOblivion:)])
			[self->delegate LDrawGLViewPartsWereDraggedIntoOblivion:self];
	}
	
	// When nobody else received the drag and nobody cares, the part is just 
	// deleted and is gone forever. We bring the solemnity of this sad and 
	// otherwise obscure passing to the user's attention by running that cute 
	// little poof animation. 
	if(		operation == NSDragOperationNone
	   &&	[self->delegate respondsToSelector:@selector(LDrawGLViewPartsWereDraggedIntoOblivion:)] )
	{
		NSShowAnimationEffect (NSAnimationEffectDisappearingItemDefault,
							   aPoint, NSZeroSize, nil, NULL, NULL);
	}
}//end draggedImage:endedAt:operation:


//========== wantsPeriodicDraggingUpdates ======================================
//
// Purpose:		By default, Cocoa gives us dragging updates even when nothing 
//				updates. We don't want that. 
//
//				By refusing periodic updates, we achieve deterministic dragging 
//				behavior. Otherwise, parts can oscillate between two positions 
//				when the mouse is held exactly halfway between two grid 
//				positions. 
//
//==============================================================================
- (BOOL) wantsPeriodicDraggingUpdates
{
	return NO;

}//end wantsPeriodicDraggingUpdates


#pragma mark -

//========== updateDirectives:withDragPosition: ================================
//
// Purpose:		Adjusts the directives so they align with the given drag 
//				location, in window coordinates. 
//
//==============================================================================
- (BOOL) updateDirectives:(NSArray *)directives
		 withDragPosition:(NSPoint)dragPointInWindow
	  depthReferencePoint:(Point3)modelReferencePoint
			constrainAxis:(BOOL)constrainAxis
{
	LDrawDrawableElement	*firstDirective			= nil;
	NSPoint					 dragPointInView		= NSZeroPoint;
	Point3					 modelPoint				= ZeroPoint3;
	Point3					 oldPosition			= ZeroPoint3;
	Point3					 constrainedPosition	= ZeroPoint3;
	Vector3					 displacement			= ZeroPoint3;
	Vector3					 cumulativeDisplacement	= ZeroPoint3;
	float					 gridSpacing			= [self->document gridSpacing];
	int						 counter				= 0;
	BOOL					 moved					= NO;
	
	firstDirective	= [directives objectAtIndex:0];
	
	
	//---------- Find Location ---------------------------------------------
	
	// Where are we?
	dragPointInView		= [self convertPoint:dragPointInWindow fromView:nil];
	oldPosition			= modelReferencePoint;
	
	// and adjust.
	modelPoint				= [self modelPointForPoint:dragPointInView depthReferencePoint:modelReferencePoint];
	displacement			= V3Sub(modelPoint, oldPosition);
	cumulativeDisplacement	= V3Sub(modelPoint, self->initialDragLocation);
	
	
	//---------- Find Actual Displacement ----------------------------------
	// When dragging, we want to move IN grid increments, not move TO grid 
	// increments. That means we snap the displacement vector itself to the 
	// grid, not part's location. That's because the part may not have been 
	// grid-aligned to begin with. 
	
	// As is conventional in graphics programs, we allow dragging to be 
	// constrained to a single axis. We will pick that axis that is furthest 
	// from the initial drag location. 
	if(constrainAxis == YES)
	{
		// Find the part's position along the constrained axis.
		cumulativeDisplacement	= V3IsolateGreatestComponent(cumulativeDisplacement);
		constrainedPosition		= V3Add(self->initialDragLocation, cumulativeDisplacement);
		
		// Get the displacement from the part's current position to the 
		// constrained one. 
		displacement = V3Sub(constrainedPosition, oldPosition);
	}
	
	// Snap the displacement to the grid.
	displacement			= [firstDirective position:displacement snappedToGrid:gridSpacing];
	
	//---------- Update the parts' positions  ------------------------------
	
	if(V3EqualPoints(displacement, ZeroPoint3) == NO)
	{
		// Move all the parts by that amount.
		for(counter = 0; counter < [directives count]; counter++)
		{
			[[directives objectAtIndex:counter] moveBy:displacement];
		}
		
		moved = YES;
	}
	
	return moved;
	
}//end updateDirectives:withDragPosition:


#pragma mark -
#pragma mark MENUS
#pragma mark -

//========== validateMenuItem: =================================================
//
// Purpose:		We control our own contextual menu. Since all its actions point 
//				into this class, this is where we manage the menu items.
//
//==============================================================================
- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
	// Check the appropriate item for the viewing angle. We have to check the 
	// action selector here so as not to start checking other items like zoomIn: 
	// that happen to have a tag which matches one of the viewing angles.) 
	if([menuItem action] == @selector(viewOrientationSelected:))
	{
		if([menuItem tag] == self->viewOrientation)
			[menuItem setState:NSOnState];
		else
			[menuItem setState:NSOffState];
	}
	
	return YES;
}//end validateMenuItem:


#pragma mark -
#pragma mark NOTIFICATIONS
#pragma mark -


//========== backgroundColorDidChange: =========================================
//
// Purpose:		The global preference for the LDraw views' background color has 
//				been changed. We need to update our display accordingly.
//
//==============================================================================
- (void) backgroundColorDidChange:(NSNotification *)notification
{
	[self takeBackgroundColorFromUserDefaults];
	
}//end backgroundColorDidChange:


//========== displayNeedsUpdating: =============================================
//
// Purpose:		Someone (likely our file) has notified us that it has changed, 
//				and thus we need to redraw.
//
//				We also use this opportunity to grow the canvas if necessary.
//
//==============================================================================
- (void) displayNeedsUpdating:(NSNotification *)notification
{
	[self resetFrameSize]; //calls setNeedsDisplay
	
}//end displayNeedsUpdating


//========== mouseToolDidChange: ===============================================
//
// Purpose:		Someone (likely our file) has notified us that it has changed, 
//				and thus we need to redraw.
//
//				We also use this opportunity to grow the canvas if necessary.
//
//==============================================================================
- (void) mouseToolDidChange:(NSNotification *)notification
{
	[self resetCursor];
	
}//end mouseToolDidChange


//========== reshape ===========================================================
//
// Purpose:		Something changed in the viewing department; we need to adjust 
//				our projection and viewing area.
//
//==============================================================================
- (void)reshape
{
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];

		NSRect	visibleRect	= [self visibleRect];
		float	scaleFactor	= [self zoomPercentage] / 100;
		
	//	NSLog(@"GL view(0x%X) reshaping; frame %@", self, NSStringFromRect(frame));
		
		//Make a new view based on the current viewable area
		[self makeProjection];

		glViewport(0,0, NSWidth(visibleRect) * scaleFactor, NSHeight(visibleRect) * scaleFactor );
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end reshape


//========== update ============================================================
//
// Purpose:		This method is called by the AppKit whenever our drawable area 
//				changes somehow. Ordinarily, we wouldn't be concerned about what 
//				happens here. However, calling -update is highly thread-unsafe, 
//				so we guard the context with a mutex here so as to avoid truly 
//				hideous system crashes.
//
//==============================================================================
- (void) update
{
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] update];
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end update

#pragma mark -
#pragma mark UTILITIES
#pragma mark -

//========== getDirectivesUnderMouse:amongDirectives:fastDraw: =================
//
// Purpose:		Finds the directives under a given mouse-click. This method is 
//				written so that the caller can optimize its hit-detection by 
//				doing a preliminary test on just the bounding boxes.
//
// Parameters:	theEvent	= mouse-click event
//				directives	= the directives under consideration for being 
//								clicked. This may be the whole File directive, 
//								or a smaller subset we have already determined 
//								(by a previous call) is in the area.
//				fastDraw	= consider only bounding boxes for hit-detection.
//
// Returns:		Array of clicked parts; the closest one -- and the only one we 
//				care about -- is always the 0th element.
//
// Notes:		There's a gotcha here. The click region is determined by 
//				isolating a 1-pixel square around the place where the mouse was 
//				clicked. This is done with gluPickMatrix.
//
//				The trouble is that gluPickMatrix works in viewport coordinates, 
//				which NONE of our Cocoa views are using! (Exception: GLViews 
//				outside a scroll view at 100% zoom level.) To avoid getting 
//				mired in the terrifying array of possible coordinate systems, 
//				we just convert both the click point and the LDraw visible rect 
//				to Window Coordinates.
//
//				Actually, I bet that is fundamentally wrong too. But it won't 
//				show up unless the window coordinate system is being modified. 
//				The ultimate solution is probably to convert to screen 
//				coordinates, because that's what OpenGL is using anyway.
//
//				Confused? So am I.
//
//==============================================================================
- (NSArray *) getDirectivesUnderMouse:(NSEvent *)theEvent
					  amongDirectives:(NSArray *)directives
							 fastDraw:(BOOL)fastDraw
{
	NSArray	*clickedDirectives	= nil;

	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];
		
		NSPoint			 viewClickedPoint			= [theEvent locationInWindow]; //window coordinates
		NSRect			 visibleRect				= [self convertRect:[self visibleRect] toView:nil]; //window coordinates.
		GLuint			 nameBuffer			[512]	= {0};
		GLint			 viewport			[4]		= {0};
		GLfloat			 projectionMatrix	[16]	= {0.0};
		int				 numberOfHits				= 0;
		int				 counter					= 0;
		unsigned int	 drawOptions				= DRAW_HIT_TEST_MODE;
		
		if(fastDraw == YES)
			drawOptions |= DRAW_BOUNDS_ONLY;
		
		glGetIntegerv(GL_VIEWPORT, viewport);
		glGetFloatv(GL_PROJECTION_MATRIX, projectionMatrix);
		
		//Prepare OpenGL to record hits in the viewing area. We need to feed it 
		// a buffer which will be filled with the tags of things that got hit.
		glSelectBuffer(512, nameBuffer);
		glRenderMode(GL_SELECT); //switch to hit-testing mode.
		{
			//Prepare for recording names. These functions must be called 
			// *after* switching to render mode.
			glInitNames();
			glPushName(UINT_MAX); //0 would be a valid choice, after all...
			
			//Restrict our rendering area (and thus our hit-testing region) to 
			// a very small rectangle around the mouse position.
			glMatrixMode(GL_PROJECTION);
			glPushMatrix();
			{
				glLoadIdentity();
				
				//Lastly, convert to viewport coordinates:
				float pickX = viewClickedPoint.x - NSMinX(visibleRect);
				float pickY = viewClickedPoint.y - NSMinY(visibleRect);
				
				gluPickMatrix(pickX,
							  pickY,
							  1, //width
							  1, //height
							  viewport);
				
				// Now re-apply the original camera matrix
				glMultMatrixf(projectionMatrix);
				
				glMatrixMode(GL_MODELVIEW);
				
				//draw all the requested directives
				for(counter = 0; counter < [directives count]; counter++)
					[[directives objectAtIndex:counter] draw:drawOptions parentColor:glColor];
			}
			//Restore original viewing matrix after mangling for the hit area.
			glMatrixMode(GL_PROJECTION);
			glPopMatrix();
			
			glFlush();
			[[self openGLContext] flushBuffer];
			
			[self setNeedsDisplay:YES];
		}
		numberOfHits = glRenderMode(GL_RENDER);
		
		clickedDirectives = [self getPartsFromHits:nameBuffer hitCount:numberOfHits];
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
	return clickedDirectives;
	
}//end getDirectivesUnderMouse:amongDirectives:fastDraw:


//========== getPartFromHits:hitCount: =========================================
//
// Purpose:		Deduce the parts that were clicked on, given the selection data 
//				returned from glMatrixMode(GL_SELECT). This hit data is created 
//				by OpenGL when we click the mouse.
//
// Parameters	numberHits is the number of hit records recorded in nameBuffer.
//					It seems to return -1 if the buffer overflowed.
//				nameBuffer is structured as follows:
//					nameBuffer[0] = number of names in first record
//					nameBuffer[1] = minimum depth hit in field of view
//					nameBuffer[2] = maximum depth hit in field of view
//					nameBuffer[3] = bottom entry on name stack
//						....
//					nameBuffer[n] = top entry on name stack
//					nameBuffer[n+1] = number names in second record
//						.... etc.
//
//				Each time something gets rendered into our picking region around 
//				the mouse (and it has a different name), it generates a hit 
//				record. So we have to investigate our buffer and figure out 
//				which hit was the nearest to the front (smallest minimum depth); 
//				that is the one we clicked on.
//
// Returns:		Array of all the parts under the click. The nearest part is 
//				guaranteed to be the first entry in the array. There is no 
//				defined order for the rest of the parts.
//
//==============================================================================
- (NSArray *) getPartsFromHits:(GLuint *)nameBuffer
					  hitCount:(GLuint)numberHits
{
	NSMutableArray	*clickedParts		= [NSMutableArray arrayWithCapacity:numberHits];
	LDrawDirective	*currentDirective	= nil;
	
	//The hit record depths are mapped between 0 and UINT_MAX, where the maximum 
	// integer is the deepest point. We are looking for the shallowest point, 
	// because that's what we clicked on.
	GLuint	minimumDepth		= UINT_MAX;
	GLuint	currentName			= 0;
	GLuint	currentDepth		= 0;
	int		numberNames			= 0;
	int		hitCounter			= 0;
	int		counter				= 0;
	int		hitRecordBaseIndex	= 0;
	
	//Process all the hits. In theory, each hit record can be of variable 
	// length, so the logic is a little messy. (In Bricksmith, each it record 
	// is exactly 4 entries long, but we're being all general here!)
	for(hitCounter = 0; hitCounter < numberHits; hitCounter++)
	{
		//We find hit records by reckoning them as starting at an 
		// offset in the buffer. hitRecordBaseIndex is the index of the 
		// first entry in the record.
		
		numberNames		= nameBuffer[hitRecordBaseIndex + 0]; //first entry.
		currentDepth	= nameBuffer[hitRecordBaseIndex + 1];
		
		//By convention in Bricksmith, we only have one name per hit, so 
		// numberNames == 1.
		for(counter = 0; counter < numberNames; counter++)
		{
			//Names start in the fourth entry of the hit.
			currentName = nameBuffer[hitRecordBaseIndex + 3 + counter];
			
		}
		currentDirective = [self getDirectiveFromHitCode:currentName];
		
		//Is this hit closer than the last closest one?
		if(currentDepth < minimumDepth)
		{
			minimumDepth = currentDepth;
			
			//If this was closer, we need to record the name at the top of the 
			// array
			[clickedParts insertObject:currentDirective atIndex:0];
		}
		else
			[clickedParts addObject:currentDirective];
		
		//Advance past this entire hit record. (Three standard entries followed 
		// by a variable number of names per record.)
		hitRecordBaseIndex += 3 + numberNames;
	}
		
	return clickedParts;
	
}//end getPartFromHits:hitCount:


//========== getDirectiveFromHitCode: ==========================================
//
// Purpose:		When we click the mouse, it generates an OpenGL hit-test in 
//				which parts that were "hit" leave a signature behind. That 
//				signature in an encoded integer which determines where in the 
//				model the part resides. This method decodes that tag.
//
// Note:		0 is a perfectly valid directive tag; our clue that we didn't 
//				find anything is if the number of hits is invalid. That 
//				information is beyond the scope of this method's knowledge.
//
//==============================================================================
- (LDrawDirective *) getDirectiveFromHitCode:(GLuint)name
{
	LDrawModel		*enclosingModel		= nil;
	LDrawStep		*enclosingStep		= nil;
	LDrawDirective	*clickedDirective	= nil;
	
	//Name tags encode the indices at which the reside.
	int	stepIndex	= name / STEP_NAME_MULTIPLIER; //integer division
	int	partIndex	= name % STEP_NAME_MULTIPLIER;
	
	//Find the reference we seek. Note that the "fileBeingDrawn" is 
	// not necessarily a file, so we have to compensate.
	if([fileBeingDrawn isKindOfClass:[LDrawFile class]] == YES)
		enclosingModel = (LDrawModel *)[(LDrawFile*)fileBeingDrawn activeModel];
	else if([fileBeingDrawn isKindOfClass:[LDrawModel class]] == YES)
		enclosingModel = (LDrawModel *)fileBeingDrawn;
	
	if(enclosingModel != nil)
	{
		enclosingStep    = [[enclosingModel steps] objectAtIndex:stepIndex];
		clickedDirective = [[enclosingStep subdirectives] objectAtIndex:partIndex];
	}
	
	return clickedDirective;
	
}//end getDirectiveFromHitCode:


//========== resetFrameSize: ===================================================
//
// Purpose:		We resize the canvas to accomodate the model. It automatically 
//				shrinks for small models and expands for large ones. Neat-o!
//
//==============================================================================
- (void) resetFrameSize
{
	if([self->fileBeingDrawn respondsToSelector:@selector(boundingBox3)] )
	{
		CGLLockContext([[self openGLContext] CGLContextObj]);
		{
			//We do not want to apply this resizing to a raw GL view.
			// It only makes sense for those in a scroll view. (The Part Browsers 
			// have been moved to scrollviews now too in order to allow zooming.)
			if([self enclosingScrollView] != nil)
			{
				//Determine whether the canvas size needs to change.
				Point3	origin			= {0,0,0};
				NSPoint	centerPoint		= [self centerPoint];
				Box3	newBounds		= InvalidBox; //cast to silence warning.
				
				newBounds = [(id)fileBeingDrawn boundingBox3]; //cast to silence warning.
				
				if(V3EqualBoxes(newBounds, InvalidBox) == NO)
				{
					//
					// Find bounds size, based on model dimensions.
					//
					
					float	distance1		= V3DistanceBetween2Points(origin, newBounds.min );
					float	distance2		= V3DistanceBetween2Points(origin, newBounds.max );
					float	newSize			= MAX(distance1, distance2) + 40; //40 is just to provide a margin.
					NSSize	contentSize		= [[self enclosingScrollView] contentSize];
					GLfloat	currentMatrix[16];
					
					contentSize = [self convertSize:contentSize fromView:[self enclosingScrollView]];
					
					//We have the canvas resizing set to a fairly large granularity, so 
					// doesn't constantly change on people.
					newSize = ceil(newSize / 384) * 384;
					
					//
					// Reposition the Camera
					//
					
					[[self openGLContext] makeCurrentContext];
					
					//As the size of the model changes, we must move the camera in and out 
					// so as to view the entire model in the right perspective. Moving the 
					// camera is equivalent to translating the modelview matrix. (That's what 
					// gluLookAt does.) 
					// Note:	glTranslatef() doesn't work here. If M is the current matrix, 
					//			and T is the translation, it performs M = M x T. But we need 
					//			M = T x M, because OpenGL uses transposed matrices.
					//			Solution: set matrix manually. Is there a better one?
					glMatrixMode(GL_MODELVIEW);
					glGetFloatv(GL_MODELVIEW_MATRIX, currentMatrix);
					
					//As cameraDistance approaches infinity, the view approximates an 
					// orthographic projection. We want a fairly large number here to 
					// produce a small, only slightly-noticable perspective.
					self->cameraDistance = - (newSize) * CAMERA_DISTANCE_FACTOR;
					currentMatrix[12] = 0; //reset the camera location. Positions 12-14 of 
					currentMatrix[13] = 0; // the matrix hold the translation values.
					currentMatrix[14] = cameraDistance;
					glLoadMatrixf(currentMatrix); // It's easiest to set them directly.

					//
					// Resize the Frame
					//
					
					NSSize	oldFrameSize	= [self frame].size;
	//				NSSize	newFrameSize	= NSMakeSize( newSize*2, newSize*2 );
					//Make the frame either just a little bit bigger than the size 
					// of the model, or the same as the scroll view, whichever is larger.
//					NSSize	newFrameSize	= NSMakeSize( MAX(newSize*2, contentSize.width),
//														  MAX(newSize*2, contentSize.height) );
					NSSize	newFrameSize	= NSMakeSize( newSize*2, newSize*2 );
					
					//The canvas size changes will effectively be distributed equally on 
					// all sides, because the model is always drawn in the center of the 
					// canvas. So, our effective viewing center will only change by half 
					// the size difference.
					centerPoint.x += (newFrameSize.width  - oldFrameSize.width)/2;
					centerPoint.y += (newFrameSize.height - oldFrameSize.height)/2;
					
					[self setFrameSize:newFrameSize];
					[self scrollCenterToPoint:centerPoint]; //must preserve this; otherwise, viewing is funky.
					
					//NSLog(@"minimum (%f, %f, %f); maximum (%f, %f, %f)", newBounds.min.x, newBounds.min.y, newBounds.min.z, newBounds.max.x, newBounds.max.y, newBounds.max.z);
					
				}//end valid bounds check
			}//end boundable check
		}
		CGLUnlockContext([[self openGLContext] CGLContextObj]);
	}
	
	[self setNeedsDisplay:YES];
}//end 


//========== restoreConfiguration ==============================================
//
// Purpose:		Restores the viewing configuration (such as camera location and 
//				projection mode) based on data found in persistent storage. Only 
//				has effect if an autosave name has been specified.
//
//==============================================================================
- (void) restoreConfiguration
{
	if(self->autosaveName != nil)
	{
		
		NSUserDefaults	*userDefaults		= [NSUserDefaults standardUserDefaults];
		NSString		*viewingAngleKey	= [NSString stringWithFormat:@"%@ %@", LDRAW_GL_VIEW_ANGLE, self->autosaveName];
		NSString		*projectionModeKey	= [NSString stringWithFormat:@"%@ %@", LDRAW_GL_VIEW_PROJECTION, self->autosaveName];
		
		[self   setViewOrientation:[userDefaults integerForKey:viewingAngleKey] ];
		[self setProjectionMode:[userDefaults integerForKey:projectionModeKey] ];
	}
	
}//end restoreConfiguration


//========== makeProjection ====================================================
//
// Purpose:		Loads the viewing projection appropriate for our canvas size.
//
//==============================================================================
- (void) makeProjection
{
	NSRect	visibleRect		= [self visibleRect];
	NSRect	frame			= [self frame];
	float	fieldDepth		= 0;
	NSRect	visibilityPlane	= NSZeroRect;
	
	//ULTRA-IMPORTANT NOTE: this method assumes that you have already made our 
	// openGLContext the current context
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		// Start from scratch
		glMatrixMode(GL_PROJECTION); //we are changing the projection, NOT the model!
		glLoadIdentity();
		
		//This is effectively equivalent to infinite field depth
		fieldDepth = MAX(NSHeight(frame), NSWidth(frame));
		
			// Once upon a time, I had a feature called "infinite field depth," 
			// as opposed to a depth that would clip the model. Eventually I 
			// concluded this was a bad idea. But for future reference, the 
			// maximum fieldDepth is about 1e6 (50,000 studs, >1300 ft; probably 
			// enough!); viewing goes haywire with bigger numbers. 
		
		float y = NSMinY(visibleRect);
		if([self isFlipped] == YES)
			y = NSHeight(frame) - y - NSHeight(visibleRect);
		
		//The projection plane is stated in model coordinates.
		visibilityPlane.origin.x	= NSMinX(visibleRect) - NSWidth(frame)/2;
		visibilityPlane.origin.y	= y - NSHeight(frame)/2;
		visibilityPlane.size.width	= NSWidth(visibleRect);
		visibilityPlane.size.height	= NSHeight(visibleRect);
		
		if(self->projectionMode == ProjectionModePerspective)
		{
			// We want perspective and ortho views to show objects at the origin 
			// as the same size. Since perspective viewing is defined by a 
			// frustum (truncated pyramid), we have to shrink the visibily 
			// plane--which is located on the near clipping plane--in such a way 
			// that the slice of the frustum at the origin will have the 
			// dimensions of the desired visibility plane. (Remember, slices 
			// grow *bigger* as they go deeper into the view. Since the origin 
			// is deeper, that means we need a near visibility plane that is 
			// *smaller* than the desired size at the origin.)  
			//
			// Find the scaling percentage betwen the frustum slice through 
			// (0,0,0) and the slice that defines the near clipping plane. 
			float visibleProportion = (fabs(self->cameraDistance) - fieldDepth)
														/
											fabs(self->cameraDistance);
			
			//scale down the visibility plane, centering it in the full-size one.
			visibilityPlane.origin.x += NSWidth(visibilityPlane)  * (1 - visibleProportion) / 2;
			visibilityPlane.origin.y += NSHeight(visibilityPlane) * (1 - visibleProportion) / 2;
			visibilityPlane.size.width	*= visibleProportion;
			visibilityPlane.size.height	*= visibleProportion;
			
			glFrustum(NSMinX(visibilityPlane),	//left
					  NSMaxX(visibilityPlane),	//right
					  NSMinY(visibilityPlane),	//bottom
					  NSMaxY(visibilityPlane),	//top
					  fabs(cameraDistance) - fieldDepth,	//near (closer points are clipped); distance from CAMERA LOCATION
					  fabs(cameraDistance) + fieldDepth		//far (points beyond this are clipped); distance from CAMERA LOCATION
					 );
		}
		else
		{
			glOrtho(NSMinX(visibilityPlane),	//left
					NSMaxX(visibilityPlane),	//right
					NSMinY(visibilityPlane),	//bottom
					NSMaxY(visibilityPlane),	//top
					fabs(cameraDistance) - fieldDepth,		//near (points beyond these are clipped)
					fabs(cameraDistance) + fieldDepth );	//far
		}
		
		
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);
	
}//end makeProjection


//========== saveConfiguration =================================================
//
// Purpose:		Saves the viewing configuration (such as camera location and 
//				projection mode) into persistent storage. Only has effect if an 
//				autosave name has been specified.
//
//==============================================================================
- (void) saveConfiguration
{
	if(self->autosaveName != nil)
	{
		NSUserDefaults	*userDefaults		= [NSUserDefaults standardUserDefaults];
		NSString		*viewingAngleKey	= [NSString stringWithFormat:@"%@ %@", LDRAW_GL_VIEW_ANGLE, self->autosaveName];
		NSString		*projectionModeKey	= [NSString stringWithFormat:@"%@ %@", LDRAW_GL_VIEW_PROJECTION, self->autosaveName];
		
		[userDefaults setInteger:[self viewOrientation]	forKey:viewingAngleKey];
		[userDefaults setInteger:[self projectionMode]	forKey:projectionModeKey];
		
		[userDefaults synchronize]; //because we may be quitting, we have to force this here.
	}

}//end saveConfiguration


//========== scrollCenterToPoint ===============================================
//
// Purpose:		Scrolls the receiver (if it is inside a scroll view) so that 
//				newCenter is at the center of the viewing area. newCenter is 
//				given in frame coordinates.
//
//==============================================================================
- (void) scrollCenterToPoint:(NSPoint)newCenter
{
	NSRect	visibleRect		= [self visibleRect];
	NSPoint	scrollOrigin	= NSMakePoint( newCenter.x - NSWidth(visibleRect)/2,
										   newCenter.y - NSHeight(visibleRect)/2);
	
	[self scrollPoint:scrollOrigin];
}//end scrollCenterToPoint:


//========== takeBackgroundColorFromUserDefaults ===============================
//
// Purpose:		The user gets to choose a background color used throughout the 
//				application. Read and use it here.
//
//==============================================================================
- (void) takeBackgroundColorFromUserDefaults
{
	NSUserDefaults	*userDefaults	= [NSUserDefaults standardUserDefaults];
	NSColor			*newColor		= [userDefaults colorForKey:LDRAW_VIEWER_BACKGROUND_COLOR_KEY];
	NSColor			*rgbColor		= nil;
	
	if(newColor == nil)
		newColor = [NSColor whiteColor];
	
	// the new color may not be in the RGB colorspace, so we need to convert.
	rgbColor = [newColor colorUsingColorSpaceName:NSDeviceRGBColorSpace];
	
	glBackgroundColor[0] = [rgbColor redComponent];
	glBackgroundColor[1] = [rgbColor greenComponent];
	glBackgroundColor[2] = [rgbColor blueComponent];
	glBackgroundColor[3] = 1.0;
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		//This method can get called from -prepareOpenGL, which is itself called 
		// from -makeCurrentContext. That's a recipe for infinite recursion. So, 
		// we only makeCurrentContext if we *need* to.
		if([NSOpenGLContext currentContext] != [self openGLContext])
			[[self openGLContext] makeCurrentContext];
		
		glClearColor( glBackgroundColor[0],
					  glBackgroundColor[1],
					  glBackgroundColor[2],
					  glBackgroundColor[3] );
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);

	[self setNeedsDisplay:YES];
	
}//end takeBackgroundColorFromUserDefaults


#pragma mark -
#pragma mark Geometry

//========== getModelAxesForViewX:Y:Z: =========================================
//
// Purpose:		Finds the axes in the model coordinate system which most closely 
//			    project onto the X, Y, Z axes of the view. 
//
// Notes:		The screen coordinate system is right-handed:
//
//					 +y
//					|
//					|
//					*-- +x
//				   /
//				  +z
//
//				The choice between what is the "closest" axis in the model is 
//			    often arbitrary, but it will always be a unique and 
//			    sensible-looking choice. 
//
//==============================================================================
- (void) getModelAxesForViewX:(Vector3 *)outModelX
							Y:(Vector3 *)outModelY
							Z:(Vector3 *)outModelZ
{
	Vector4 screenX		= {1,0,0,1};
	Vector4 screenY		= {0,1,0,1};
	Vector4 unprojectedX, unprojectedY; //the vectors in the model which are projected onto x,y on screen
	Vector3 modelX, modelY, modelZ; //the closest model axes to which the screen's x,y,z align
	
	// Translate the x, y, and z vectors on the surface of the screen into the 
	// axes to which they most closely align in the model itself. 
	// This requires the inverse of the current transformation matrix, so we can 
	// convert projection-coordinates back to the model coordinates they are 
	// displaying. 
	Matrix4 inversed = [self getInverseMatrix];
	
	//find the vectors in the model which project onto the screen's axes
	// (We only care about x and y because this is a two-dimensional 
	// projection, and the third axis is consquently ambiguous. See below.) 
	unprojectedX = V4MulPointByMatrix(screenX, inversed);
	unprojectedY = V4MulPointByMatrix(screenY, inversed);
	
	//find the actual axes closest to those model vectors
	modelX	= V3FromV4(unprojectedX);
	modelY	= V3FromV4(unprojectedY);
	
	modelX	= V3IsolateGreatestComponent(modelX);
	modelY	= V3IsolateGreatestComponent(modelY);
	
	modelX	= V3Normalize(modelX);
	modelY	= V3Normalize(modelY);
	
	// The z-axis is often ambiguous because we are working backwards from a 
	// two-dimensional screen. Thankfully, while the process used for deriving 
	// the x and y vectors is perhaps somewhat arbitrary, it always yields 
	// sensible and unique results. Thus we can simply derive the z-vector, 
	// which will be whatever axis x and y *didn't* land on. 
	modelZ = V3Cross(modelX, modelY);
	
	if(outModelX != NULL)
		*outModelX = modelX;
	if(outModelY != NULL)
		*outModelY = modelY;
	if(outModelZ != NULL)
		*outModelZ = modelZ;
	
}//end getModelAxesForViewX:Y:Z:


//========== modelPointForPoint:depthReferencePoint: ===========================
//
// Purpose:		Unprojects the given point (in view coordinates) back into a 
//			    point in the model which projects there. 
//
// Notes:		Any point on the screen represents the projected location of an 
//			    infinite number of model points, extending on a line from the 
//			    near to the far clipping plane. 
//
//				It's impossible to boil that down to a single point without 
//			    being given some known point in the model to determine the 
//			    desired depth. (Hence the depthPoint parameter.) The returned 
//			    point will lie on a plane which contains depthPoint and is 
//			    perpendicular to the model axis most closely aligned to the 
//			    computer screen's z-axis. 
//
//										* * * *
//
//				When viewing the model with an orthographic projection and the 
//			    camera pointing parallel to one of the model's coordinate axes, 
//				this method is useful for determining two of the three 
//			    coordinates over which the mouse is hovering. To find which 
//			    coordinate is bogus, we call -getModelAxesForViewX:Y:Z:. The 
//			    returned z-axis indicates the unreliable point. 
//
//==============================================================================
- (Point3) modelPointForPoint:(NSPoint)viewPoint
		  depthReferencePoint:(Point3)depthPoint
{
	GLdouble	modelViewGLMatrix	[16];
	GLdouble	projectionGLMatrix	[16];
	GLint		viewport			[4];
	GLdouble	glNearModelPoint	[3];
	GLdouble	glFarModelPoint		[3];
	Point3		modelPoint				= ZeroPoint3;
	NSRect		contextRectInWindow		= [self convertRect:[self visibleRect] toView:nil];
	NSPoint		windowPoint				= [self convertPoint:viewPoint toView:nil];
	NSPoint		contextPoint			= NSZeroPoint;
	Vector3		modelZ;
	float		t						= 0; //parametric variable
	
	CGLLockContext([[self openGLContext] CGLContextObj]);
	{
		[[self openGLContext] makeCurrentContext];
	
		// To map the 2D view point back into a 3D model coordinate, we'll use 
		// the gluUnProject convenience function. It takes values in "window 
		// coordinates," which are really coordinates relative to the OpenGL 
		// context's drawing area. The context is always as big as the visible 
		// area of the NSOpenGLView, and is basically splattered up on the 
		// window. So the easiest way to get coordinates is to express both the 
		// view point and context area in window coordinates. That frees us from 
		// worrying about view scaling. 
		
		// need to get viewPoint in terms of the viewport!
		contextPoint.x = windowPoint.x - NSMinX(contextRectInWindow);
		contextPoint.y = windowPoint.y - NSMinY(contextRectInWindow);
		
		glGetDoublev(GL_PROJECTION_MATRIX, projectionGLMatrix);
		glGetDoublev(GL_MODELVIEW_MATRIX, modelViewGLMatrix);
		glGetIntegerv(GL_VIEWPORT, viewport);
		
		// gluUnProject takes a window "z" coordinate. These values range from 
		// 0.0 (on the near clipping plane) to 1.0 (the far clipping plane). 
		
		// - Near clipping plane unprojection
		gluUnProject( contextPoint.x,
					  contextPoint.y,
					  0.0, //z
					  modelViewGLMatrix,
					  projectionGLMatrix,
					  viewport,
					  &glNearModelPoint[0],
					  &glNearModelPoint[1],
					  &glNearModelPoint[2] );
		
		// - Far clipping plane unprojection
		gluUnProject( contextPoint.x,
					  contextPoint.y,
					  1.0, //z
					  modelViewGLMatrix,
					  projectionGLMatrix,
					  viewport,
					  &glFarModelPoint[0],
					  &glFarModelPoint[1],
					  &glFarModelPoint[2] );
		
		//---------- Derive the actual point from the depth point --------------
		//
		// We now have two accurate unprojected coordinates: the near (P1) and 
		// far (P2) points of the line through 3-D space which projects onto the 
		// single screen point. 
		//
		// The parametric equation for a line given two points is:
		//
		//		 /      \														/
		//	 L = | 1 - t | P  + t P        (see? at t=0, L = P1 and at t=1, L = P2.
		//		 \      /   1      2
		//
		// So for example,	z = (1-t)*z1 + t*z2
		//					z = z1 - t*z1 + t*z2
		//
		//								/       \								/
		//					 z = z  - t | z - z  |
		//						  1     \  1   2/
		//
		//
		//						  z  - z
		//						   1			No need to worry about dividing 
		//					 t = ---------		by 0 because the axis we are 
		//						  z  - z		inspecting will never be 
		//						   1    2		perpendicular to the screen.

		// Which axis are we going to use from the reference point?
		[self getModelAxesForViewX:NULL Y:NULL Z:&modelZ];
		
		// Find the value of the parameter at the depth point.
		if(modelZ.x != 0)
			t = (glNearModelPoint[0] - depthPoint.x) / (glNearModelPoint[0] - glFarModelPoint[0]);
		
		else if(modelZ.y != 0)
			t = (glNearModelPoint[1] - depthPoint.y) / (glNearModelPoint[1] - glFarModelPoint[1]);
		
		else if(modelZ.z != 0)
			t = (glNearModelPoint[2] - depthPoint.z) / (glNearModelPoint[2] - glFarModelPoint[2]);
		
		// Evaluate the equation of the near-to-far line at the parameter for 
		// the depth point. 
		modelPoint.x = LERP(t, glNearModelPoint[0], glFarModelPoint[0]);
		modelPoint.y = LERP(t, glNearModelPoint[1], glFarModelPoint[1]);
		modelPoint.z = LERP(t, glNearModelPoint[2], glFarModelPoint[2]);
	}
	CGLUnlockContext([[self openGLContext] CGLContextObj]);

	return modelPoint;
	
}//end modelPointForPoint:depthReferencePoint:


#pragma mark -
#pragma mark DESTRUCTOR
#pragma mark -

//========== dealloc ===========================================================
//
// Purpose:		glFinishForever();
//
//==============================================================================
- (void) dealloc
{
	[self saveConfiguration];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[autosaveName	release];
	[fileBeingDrawn	release];

	[super dealloc];
	
}//end dealloc


@end
