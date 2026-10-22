#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WXPAppInfoProvider : NSObject

+ (instancetype)sharedProvider;
- (BOOL)hasCachedApplications;
- (void)refreshApplicationsWithCompletion:(void (^ _Nullable)(NSArray<NSDictionary *> *applications))completion;
- (NSArray<NSDictionary *> *)sortedApplicationsWithConfiguredBundleIdentifiers:(NSSet<NSString *> *)configuredBundleIdentifiers
                                                          onlyConfiguredApps:(BOOL)onlyConfiguredApps
                                                                showSystemApps:(BOOL)showSystemApps
                                                                 showTrollApps:(BOOL)showTrollApps;
- (NSString *)displayNameForBundleIdentifier:(NSString *)bundleIdentifier;
- (UIImage * _Nullable)iconForBundleIdentifier:(NSString *)bundleIdentifier;

@end

NS_ASSUME_NONNULL_END
