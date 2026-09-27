#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int result = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return result;
}
