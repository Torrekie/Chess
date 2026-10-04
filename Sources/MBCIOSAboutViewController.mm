/* UIKit About screen using the same app metadata as the macOS About panel. */

#import "MBCIOSAboutViewController.h"
#import "MBCIOSLocalization.h"

@interface MBCIOSAboutViewController ()
@property (nonatomic, copy, nullable) NSString *licenseText;
@end

@implementation MBCIOSAboutViewController

- (instancetype)init
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationFormSheet;
        self.preferredContentSize = CGSizeMake(480.0, 560.0);
    }
    return self;
}

static UILabel *MBCAboutLabel(NSString *text, UIFont *font, UIColor *color)
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};
    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"Chess";
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"";
    NSString *build = info[@"CFBundleVersion"] ?: @"";
    NSString *copyright = info[@"NSHumanReadableCopyright"];
    if (!copyright.length) copyright = @"© 2003–2024 Apple Inc.";
    NSURL *licenseURL = [bundle URLForResource:@"COPYING" withExtension:nil];
    if (!licenseURL) licenseURL = [bundle URLForResource:@"Chess" withExtension:@"txt"];
    self.licenseText = licenseURL
        ? [NSString stringWithContentsOfURL:licenseURL encoding:NSUTF8StringEncoding error:nil]
        : nil;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    UIStackView *content = [[UIStackView alloc] initWithFrame:CGRectZero];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentFill;
    content.spacing = 14.0;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:28.0],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-28.0],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12.0],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-56.0]
    ]];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:MBCIOSLocalizedString(@"ios_done", @"Done") forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    done.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    done.accessibilityIdentifier = @"about-done";
    [done addTarget:self action:@selector(closeAbout:) forControlEvents:UIControlEventTouchUpInside];
    [content addArrangedSubview:done];

    UIView *iconContainer = [[UIView alloc] initWithFrame:CGRectZero];
    [iconContainer.heightAnchor constraintEqualToConstant:88.0].active = YES;
    [content addArrangedSubview:iconContainer];
    UIImage *appIcon = [UIImage imageNamed:@"AppIcon"];
    if (appIcon) {
        UIImageView *icon = [[UIImageView alloc] initWithImage:appIcon];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.layer.cornerRadius = 16.0;
        icon.layer.cornerCurve = kCACornerCurveContinuous;
        icon.layer.masksToBounds = YES;
        icon.accessibilityLabel = name;
        [iconContainer addSubview:icon];
        [NSLayoutConstraint activateConstraints:@[
            [icon.widthAnchor constraintEqualToConstant:80.0],
            [icon.heightAnchor constraintEqualToConstant:80.0],
            [icon.centerXAnchor constraintEqualToAnchor:iconContainer.centerXAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:iconContainer.centerYAnchor]
        ]];
    } else {
        UILabel *knight = MBCAboutLabel(@"♞", [UIFont systemFontOfSize:72.0],
                                         UIColor.labelColor);
        knight.translatesAutoresizingMaskIntoConstraints = NO;
        knight.isAccessibilityElement = NO;
        [iconContainer addSubview:knight];
        [NSLayoutConstraint activateConstraints:@[
            [knight.centerXAnchor constraintEqualToAnchor:iconContainer.centerXAnchor],
            [knight.centerYAnchor constraintEqualToAnchor:iconContainer.centerYAnchor]
        ]];
    }

    UILabel *title = MBCAboutLabel(name, [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle],
                                   UIColor.labelColor);
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    [content addArrangedSubview:title];

    NSString *versionLine = nil;
    if (version.length && build.length) {
        versionLine = [NSString stringWithFormat:MBCIOSLocalizedString(@"ios_about_version_build",
                                                                       @"Version %@ (Build %@)"), version, build];
    } else if (version.length) {
        versionLine = [NSString stringWithFormat:MBCIOSLocalizedString(@"ios_about_version",
                                                                       @"Version %@"), version];
    } else {
        versionLine = [NSString stringWithFormat:MBCIOSLocalizedString(@"ios_about_build",
                                                                       @"Build %@"), build];
    }
    UILabel *versionLabel = MBCAboutLabel(versionLine,
                                         [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
                                         UIColor.secondaryLabelColor);
    [content addArrangedSubview:versionLabel];

    NSString *buildTag = info[@"MBCBuildTag"];
    if (buildTag.length) {
        UILabel *tag = MBCAboutLabel(buildTag,
                                     [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
                                     UIColor.secondaryLabelColor);
        [content addArrangedSubview:tag];
    }

    UILabel *copyrightLabel = MBCAboutLabel(copyright,
                                            [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
                                            UIColor.secondaryLabelColor);
    [content addArrangedSubview:copyrightLabel];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.backgroundColor = UIColor.separatorColor;
    [separator.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    [content addArrangedSubview:separator];

    UILabel *descriptionLabel = MBCAboutLabel(
        MBCIOSLocalizedString(@"ios_about_description",
                              @"Play Chess on iPhone and iPad, including the classic Chess variants."),
        [UIFont preferredFontForTextStyle:UIFontTextStyleBody], UIColor.labelColor);
    [content addArrangedSubview:descriptionLabel];

    UILabel *sourceLabel = MBCAboutLabel(
        MBCIOSLocalizedString(@"ios_about_source_attribution",
                              @"Based on Apple Chess 570.1. Chess engine: sjeng."),
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        UIColor.secondaryLabelColor);
    sourceLabel.accessibilityIdentifier = @"about-source-attribution";
    [content addArrangedSubview:sourceLabel];

    if (self.licenseText.length) {
        UIButton *licenseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [licenseButton setTitle:MBCIOSLocalizedString(@"ios_about_licenses", @"Open Source License")
                      forState:UIControlStateNormal];
        licenseButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        licenseButton.accessibilityIdentifier = @"about-license";
        [licenseButton addTarget:self action:@selector(showLicense:)
                forControlEvents:UIControlEventTouchUpInside];
        [content addArrangedSubview:licenseButton];
    }
}

- (void)closeAbout:(id)sender
{
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showLicense:(id)sender
{
    (void)sender;
    if (!self.licenseText.length) return;
    UIViewController *controller = [[UIViewController alloc] initWithNibName:nil bundle:nil];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    controller.title = MBCIOSLocalizedString(@"ios_about_licenses", @"Open Source License");
    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightRegular];
    textView.text = self.licenseText;
    textView.textContainerInset = UIEdgeInsetsMake(16.0, 18.0, 16.0, 18.0);
    [controller.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor],
        [textView.topAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.topAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    controller.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
                         action:@selector(closeLicense:)];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)closeLicense:(id)sender
{
    (void)sender;
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
}

@end
