#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>

// Declarations of exported Zig C-API functions
extern void popclip_init(void);
extern int popclip_analyze_selection(const char* text);
extern const char* popclip_get_action_id(int index);
extern const char* popclip_get_action_label(int index);
extern int popclip_get_action_kind(int index);
extern const char* popclip_get_action_payload(int index);
extern void popclip_calculate_placement(double sel_x, double sel_y, double sel_w, double sel_h,
                                        double screen_w, double screen_h,
                                        double* out_x, double* out_y, int* out_arrow_below);
extern int popclip_evaluate_math(const char* expr, double* out_val);
extern int popclip_is_url(const char* text);
extern int popclip_is_email(const char* text);
extern int popclip_transform_text(const char* text, int transform_kind, char* out_buf, int max_len);
extern size_t popclip_get_engine_allocated_bytes(void);
extern uint64_t popclip_get_memory_rss_bytes(void);
extern double popclip_get_memory_rss_mb(void);
extern int popclip_parse_yaml(const char* yaml, char* out_name, int max_len);
extern int popclip_append_clipboard_text(const char* current, const char* text, char* out_buf, int max_len);
extern int popclip_config_get(const char* key, char* out_buf, int max_len);
extern int popclip_config_set(const char* key, const char* val);

@interface PopClipZigTests : XCTestCase
@end

@implementation PopClipZigTests

- (void)setUp {
    [super setUp];
    popclip_init();
}

// 1. Verify engine initialization
- (void)testEngineInitialization {
    popclip_init();
    int count = popclip_analyze_selection("");
    XCTAssertEqual(count, 0, @"Empty selection should yield 0 selection actions");
}

// 2. Test URL detection and action generation
- (void)testUrlSelectionDetectionAndAction {
    const char *urlStr = "https://github.com/justrach/nanoui";
    XCTAssertEqual(popclip_is_url(urlStr), 1, @"URL detection should return true for https url");
    
    int count = popclip_analyze_selection(urlStr);
    XCTAssertTrue(count > 0, @"Selection should generate actions");
    
    BOOL foundUrlAction = NO;
    for (int i = 0; i < count; i++) {
        const char *label = popclip_get_action_label(i);
        const char *actId = popclip_get_action_id(i);
        if (strcmp(actId, "open_url") == 0) {
            foundUrlAction = YES;
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @"Open Link");
            const char *payload = popclip_get_action_payload(i);
            XCTAssertEqualObjects([NSString stringWithUTF8String:payload], [NSString stringWithUTF8String:urlStr]);
        }
    }
    XCTAssertTrue(foundUrlAction, @"'Open Link' action must be present for URLs");
}

// 3. Test Email detection and action generation
- (void)testEmailSelectionDetectionAndAction {
    const char *emailStr = "support@pilotmoon.com";
    XCTAssertEqual(popclip_is_email(emailStr), 1, @"Email detection should return true for email");
    
    int count = popclip_analyze_selection(emailStr);
    BOOL foundEmailAction = NO;
    for (int i = 0; i < count; i++) {
        const char *actId = popclip_get_action_id(i);
        if (strcmp(actId, "email") == 0) {
            foundEmailAction = YES;
            const char *label = popclip_get_action_label(i);
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @"Email");
        }
    }
    XCTAssertTrue(foundEmailAction, @"'Email' action must be present for email addresses");
}

// 4. Test Math expression evaluation
- (void)testMathExpressionEvaluation {
    double result = 0;
    int success = popclip_evaluate_math("(25 * 4) + 18", &result);
    XCTAssertEqual(success, 1, @"Math evaluation should succeed for (25 * 4) + 18");
    XCTAssertEqualWithAccuracy(result, 118.0, 0.001);
    
    // Test that math expression creates a Calculate action
    int count = popclip_analyze_selection("12 * 8");
    BOOL foundCalcAction = NO;
    for (int i = 0; i < count; i++) {
        const char *actId = popclip_get_action_id(i);
        if (strcmp(actId, "calculate") == 0) {
            foundCalcAction = YES;
            const char *label = popclip_get_action_label(i);
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @"= 96");
        }
    }
    XCTAssertTrue(foundCalcAction, @"Calculate action '= 96' must be present");
}

// 5. Test Case Transformations
- (void)testCaseTransformations {
    char buf[128];
    // 0 = UPPER
    int len = popclip_transform_text("hello world", 0, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"HELLO WORLD");
    
    // 1 = lower
    len = popclip_transform_text("HELLO WORLD", 1, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"hello world");
    
    // 2 = Title
    len = popclip_transform_text("hello world from zig", 2, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"Hello World From Zig");
}

// 6. Test Markdown Formatting
- (void)testMarkdownFormatting {
    char buf[128];
    // 3 = Bold
    int len = popclip_transform_text("important", 3, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"**important**");
    
    // 4 = Italic
    len = popclip_transform_text("slanted", 4, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"*slanted*");
    
    // 5 = Code
    len = popclip_transform_text("console.log", 5, buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"`console.log`");
}

// 7. Test Placement Algorithm Parity (Centered horizontally, 28px height, flip when near top)
- (void)testPlacementAlgorithmParity {
    double out_x = 0, out_y = 0;
    int arrow_below = 0;
    
    // Normal middle of screen: sel at (500, 400), size (100, 20)
    // Screen (1920, 1080)
    popclip_calculate_placement(500, 400, 100, 20, 1920, 1080, &out_x, &out_y, &arrow_below);
    
    // Centered: 500 + (100 - 160)/2 = 470
    XCTAssertEqualWithAccuracy(out_x, 470.0, 0.01);
    // Above: 400 - 28 - 8 = 364
    XCTAssertEqualWithAccuracy(out_y, 364.0, 0.01);
    XCTAssertEqual(arrow_below, 1, @"Arrow points down to selection below");
    
    // Near top edge: sel at (500, 30) -> should flip below
    popclip_calculate_placement(500, 30, 100, 20, 1920, 1080, &out_x, &out_y, &arrow_below);
    // Below: 30 + 20 + 8 = 58
    XCTAssertEqualWithAccuracy(out_y, 58.0, 0.01);
    XCTAssertEqual(arrow_below, 0, @"Arrow points up to selection above when flipped");
}

// 8. Test PopClip Extension YAML compatibility
- (void)testPopClipExtensionYamlCompatibility {
    const char *yamlSnippet = 
        "#popclip\n"
        "name: Translate to French\n"
        "icon: translate\n"
        "url: https://translate.google.com/?text=***\n";
    
    char nameBuf[128];
    int len = popclip_parse_yaml(yamlSnippet, nameBuf, sizeof(nameBuf));
    XCTAssertTrue(len > 0, @"YAML parsing should succeed");
    XCTAssertEqualObjects([NSString stringWithUTF8String:nameBuf], @"Translate to French");
}

// 9. Benchmark: Memory Consumption Under 5MB
- (void)testMemoryConsumptionUnder5MB {
    popclip_analyze_selection("https://github.com/justrach/nanoui");
    size_t engineBytes = popclip_get_engine_allocated_bytes();
    double engineKB = (double)engineBytes / 1024.0;
    NSLog(@"[XCTest Benchmark] Zig PopClip Dynamic Heap Memory: %.2f KB (%zu bytes)", engineKB, engineBytes);
    
    // The Zig PopClip engine itself must allocate under 1 MB (< 1024 KB), typically < 10 KB!
    XCTAssertTrue(engineKB < 1024.0, @"Zig PopClip heap memory must be strictly under 1 MB (measured: %.2f KB)", engineKB);
}

// 10. End to end full selection pipeline
- (void)testEndToEndSelectionToActions {
    const char *sample = "Quick brown fox";
    int count = popclip_analyze_selection(sample);
    XCTAssertTrue(count >= 7, @"Should generate Copy, Cut, Search, Case transforms, Markdown, Word Count");
    
    // Check that standard Copy is the first action
    XCTAssertEqualObjects([NSString stringWithUTF8String:popclip_get_action_id(0)], @"copy");
    XCTAssertEqualObjects([NSString stringWithUTF8String:popclip_get_action_label(0)], @"Copy");
}

// 11. Test Append to Clipboard Action
- (void)testAppendToClipboardAction {
    char buf[256];
    int len = popclip_append_clipboard_text("Existing clipboard line", "New appended text", buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"Existing clipboard line\nNew appended text");
}

// 12. Test Image Parity: Terminal (>_), Append (+), and Notes actions
- (void)testImageParityActionsPresence {
    int count = popclip_analyze_selection("企业文化");
    XCTAssertTrue(count > 0);
    
    BOOL foundTerminal = NO;
    BOOL foundAppend = NO;
    BOOL foundNotes = NO;
    
    for (int i = 0; i < count; i++) {
        const char *actId = popclip_get_action_id(i);
        const char *label = popclip_get_action_label(i);
        if (strcmp(actId, "terminal") == 0) {
            foundTerminal = YES;
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @">_");
        } else if (strcmp(actId, "append") == 0) {
            foundAppend = YES;
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @"+");
        } else if (strcmp(actId, "notes") == 0) {
            foundNotes = YES;
            XCTAssertEqualObjects([NSString stringWithUTF8String:label], @"Notes");
        }
    }
    
    XCTAssertTrue(foundTerminal, @"Terminal (>_) action must be present (Image #1)");
    XCTAssertTrue(foundAppend, @"Append (+) action must be present (Image #1)");
    XCTAssertTrue(foundNotes, @"Notes action must be present (Image #1)");
}

// 13. Test Config Get and Set
- (void)testConfigGetAndSet {
    char buf[256];
    int len = popclip_config_get("theme", buf, sizeof(buf));
    XCTAssertTrue(len > 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"dark");
    
    int ok = popclip_config_set("theme", "light");
    XCTAssertEqual(ok, 1);
    
    len = popclip_config_get("theme", buf, sizeof(buf));
    XCTAssertEqualObjects([NSString stringWithUTF8String:buf], @"light");
}

@end
