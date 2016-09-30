/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

#import <Foundation/Foundation.h>
#import "Logging.h"
#import "server_globals.h"
#import "NeoVimServer.h"
#import "NeoVimUiBridgeProtocol.h"
#import "NeoVimBuffer.h"
#import "CocoaCategories.h"

// FileInfo and Boolean are #defined by Carbon and NeoVim: Since we don't need the Carbon versions of them, we rename
// them.
#define FileInfo CarbonFileInfo
#define Boolean CarbonBoolean

#import <nvim/vim.h>
#import <nvim/api/vim.h>
#import <nvim/ui.h>
#import <nvim/ui_bridge.h>
#import <nvim/main.h>
#import <nvim/ex_docmd.h>
#import <nvim/ex_getln.h>
#import <nvim/fileio.h>
#import <nvim/undo.h>
#import <nvim/eval.h>


#define pun_type(t, x) (*((t *) (&(x))))

typedef struct {
    UIBridgeData *bridge;
    Loop *loop;

    bool stop;
} ServerUiData;

// We declare nvim_main because it's not declared in any header files of neovim
extern int nvim_main(int argc, char **argv);

static unsigned int _default_foreground = qDefaultForeground;
static unsigned int _default_background = qDefaultBackground;
static unsigned int _default_special = qDefaultSpecial;

// The thread in which neovim's main runs
static uv_thread_t _nvim_thread;

// Condition variable used by the XPC's init to wait till our custom UI initialization is finished inside neovim
static bool _is_ui_launched = false;
static uv_mutex_t _mutex;
static uv_cond_t _condition;

static ServerUiData *_server_ui_data;

static NSString *_marked_text = nil;

static int _marked_row = 0;
static int _marked_column = 0;

// for 하 -> hanja popup, Cocoa first inserts 하, then sets marked text, cf docs/notes-on-cocoa-text-input.md
static int _marked_delta = 0;

static int _put_row = -1;
static int _put_column = -1;

static bool _dirty = false;

static NSString *_backspace = nil;

static dispatch_queue_t _queue;

static inline int screen_cursor_row() {
  return curwin->w_winrow + curwin->w_wrow;
}

static inline int screen_cursor_column() {
  return curwin->w_wincol + curwin->w_wcol;
}

static inline void queue(void (^block)()) {
  dispatch_sync(_queue, ^{
    @autoreleasepool {
      block();
    }
  });
}

static void set_ui_size(UIBridgeData *bridge, int width, int height) {
  bridge->ui->width = width;
  bridge->ui->height = height;
  bridge->bridge.width = width;
  bridge->bridge.height = height;
}

static void server_ui_scheduler(Event event, void *d) {
  UI *ui = d;
  ServerUiData *data = ui->data;
  loop_schedule(data->loop, event);
}

static void server_ui_main(UIBridgeData *bridge, UI *ui) {
  Loop loop;
  loop_init(&loop, NULL);

  _server_ui_data = xcalloc(1, sizeof(ServerUiData));
  ui->data = _server_ui_data;
  _server_ui_data->bridge = bridge;
  _server_ui_data->loop = &loop;

  set_ui_size(bridge, 30, 15);

  _server_ui_data->stop = false;
  CONTINUE(bridge);

  uv_mutex_lock(&_mutex);
  _is_ui_launched = true;
  uv_cond_signal(&_condition);
  uv_mutex_unlock(&_mutex);

  while (!_server_ui_data->stop) {
    loop_poll_events(&loop, -1);
  }

  ui_bridge_stopped(bridge);
  loop_close(&loop);

  xfree(_server_ui_data);
  xfree(ui);
}

#pragma mark NeoVim's UI callbacks

static void server_ui_resize(UI *ui __unused, int width, int height) {
  queue(^{
    int values[] = { width, height };
    NSData *data = [[NSData alloc] initWithBytes:values length:(2 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdResize data:data];
    [data release];
  });
}

static void server_ui_clear(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdClear];
  });
}

static void server_ui_eol_clear(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdEolClear];
  });
}

static void server_ui_cursor_goto(UI *ui __unused, int row, int col) {
  queue(^{
    _put_row = row;
    _put_column = col;

    int values[] = { row, col, screen_cursor_row(), screen_cursor_column() };
    DLOG("%d:%d - %d:%d", values[0], values[1], values[2], values[3]);
    NSData *data = [[NSData alloc] initWithBytes:values length:(4 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetPosition data:data];
    [data release];
  });
}

static void server_ui_update_menu(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetMenu];
  });
}

static void server_ui_busy_start(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdBusyStart];
  });
}

static void server_ui_busy_stop(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdBusyStop];
  });
}

static void server_ui_mouse_on(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdMouseOn];
  });
}

static void server_ui_mouse_off(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdMouseOff];
  });
}

static void server_ui_mode_change(UI *ui __unused, int mode) {
  queue(^{
    int value = mode;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdModeChange data:data];
    [data release];
  });
}

static void server_ui_set_scroll_region(UI *ui __unused, int top, int bot, int left, int right) {
  queue(^{
    int values[] = { top, bot, left, right };
    NSData *data = [[NSData alloc] initWithBytes:values length:(4 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetScrollRegion data:data];
    [data release];
  });
}

static void server_ui_scroll(UI *ui __unused, int count) {
  queue(^{
    int value = count;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdScroll data:data];
    [data release];
  });
}

static void server_ui_highlight_set(UI *ui __unused, HlAttrs attrs) {
  queue(^{
    FontTrait trait = FontTraitNone;
    if (attrs.italic) {
      trait |= FontTraitItalic;
    }
    if (attrs.bold) {
      trait |= FontTraitBold;
    }
    if (attrs.underline) {
      trait |= FontTraitUnderline;
    }
    if (attrs.undercurl) {
      trait |= FontTraitUndercurl;
    }
    CellAttributes cellAttrs;
    cellAttrs.fontTrait = trait;

    unsigned int fg = attrs.foreground == -1 ? _default_foreground : pun_type(unsigned int, attrs.foreground);
    unsigned int bg = attrs.background == -1 ? _default_background : pun_type(unsigned int, attrs.background);

    cellAttrs.foreground = attrs.reverse ? bg : fg;
    cellAttrs.background = attrs.reverse ? fg : bg;
    cellAttrs.special = attrs.special == -1 ? _default_special : pun_type(unsigned int, attrs.special);

    NSData *data = [[NSData alloc] initWithBytes:&cellAttrs length:sizeof(CellAttributes)];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetHighlightAttributes data:data];
    [data release];
  });
}

static void server_ui_put(UI *ui __unused, uint8_t *str, size_t len) {
  queue(^{
    NSString *string = [[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding];
    int cursor[] = { screen_cursor_row(), screen_cursor_column() };

    NSMutableData *data = [[NSMutableData alloc]
        initWithCapacity:2 * sizeof(int) + [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    [data appendBytes:cursor length:2 * sizeof(int)];
    [data appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];

    if (_marked_text != nil && _marked_row == _put_row && _marked_column == _put_column) {
      DLOG("putting marked text: '%s'", string.cstr);
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdPutMarked data:data];
    } else if (_marked_text != nil && len == 0 && _marked_row == _put_row && _marked_column == _put_column - 1) {
      DLOG("putting marked text cuz zero");
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdPutMarked data:data];
    } else {
      DLOG("putting non-marked text: '%s'", string.cstr);
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdPut data:data];
    }

    _put_column += 1;

    [data release];
    [string release];
  });
}

static void server_ui_bell(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdBell];
  });
}

static void server_ui_visual_bell(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdVisualBell];
  });
}

static void server_ui_flush(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdFlush];
  });
}

static void server_ui_update_fg(UI *ui __unused, int fg) {
  queue(^{
    int value[2];
    value[1] = *p_bg == 'd' ? true : false;

    if (fg == -1) {
      value[0] = _default_foreground;
      NSData *data = [[NSData alloc] initWithBytes:value length:(2 * sizeof(int))];
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetForeground data:data];
      [data release];

      return;
    }

    _default_foreground = pun_type(unsigned int, fg);

    value[0] = fg;
    NSData *data = [[NSData alloc] initWithBytes:value length:(2 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetForeground data:data];
    [data release];
  });
}

static void server_ui_update_bg(UI *ui __unused, int bg) {
  queue(^{
    int value[2];
    value[1] = *p_bg == 'd' ? true : false;

    if (bg == -1) {
      value[0] = _default_background;
      NSData *data = [[NSData alloc] initWithBytes:value length:(2 * sizeof(int))];
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetBackground data:data];
      [data release];

      return;
    }

    _default_background = pun_type(unsigned int, bg);
    value[0] = bg;
    NSData *data = [[NSData alloc] initWithBytes:value length:(2 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetBackground data:data];
    [data release];
  });
}

static void server_ui_update_sp(UI *ui __unused, int sp) {
  queue(^{
    int value[2];
    value[1] = *p_bg == 'd' ? true : false;

    if (sp == -1) {
      value[0] = _default_special;
      NSData *data = [[NSData alloc] initWithBytes:&value length:(2 * sizeof(int))];
      [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetSpecial data:data];
      [data release];

      return;
    }

    _default_special = pun_type(unsigned int, sp);
    value[0] = sp;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(2 * sizeof(int))];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetSpecial data:data];
    [data release];
  });
}

static void server_ui_set_title(UI *ui __unused, char *title) {
  if (title == NULL) {
    return;
  }

  queue(^{
    NSString *string = [[NSString alloc] initWithCString:title encoding:NSUTF8StringEncoding];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetTitle data:[string dataUsingEncoding:NSUTF8StringEncoding]];
    [string release];
  });
}

static void server_ui_set_icon(UI *ui __unused, char *icon) {
  if (icon == NULL) {
    return;
  }

  queue(^{
    NSString *string = [[NSString alloc] initWithCString:icon encoding:NSUTF8StringEncoding];
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdSetIcon data:[string dataUsingEncoding:NSUTF8StringEncoding]];
    [string release];
  });
}

static void server_ui_stop(UI *ui __unused) {
  queue(^{
    [_neovim_server sendMessageWithId:NeoVimServerMsgIdStop];

    ServerUiData *data = (ServerUiData *) ui->data;
    data->stop = true;
  });
}

#pragma mark Helper functions

static void refresh_ui(void **argv __unused) {
  ui_refresh();
}

static void neovim_command(void **argv) {
  @autoreleasepool {
    NSString *input = (NSString *) argv[0];

    Error err;
    vim_command((String) {
        .data = (char *) input.cstr,
        .size = [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
    }, &err);

    // FIXME: handle err.set == true

    [input release]; // retained in loop_schedule(&main_loop, ...) (in _queue) somewhere
  }
}

static void neovim_command_output(void **argv) {
  @autoreleasepool {
    NSUInteger *values = (NSUInteger *) argv[0];
    NSUInteger responseId = values[0];
    NSString *input = (NSString *) argv[1];

    Error err;
    // We don't know why nvim_command_output does not work when the optimization level is set to -Os.
    // If set to -O0, nvim_command_output works fine... -_-
    // String commandOutput = nvim_command_output((String) {
    //     .data = (char *) input.cstr,
    //     .size = [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
    // }, &err);
    do_cmdline_cmd("redir => v:command_output");
    vim_command((String) {
        .data = (char *) input.cstr,
        .size = [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
    }, &err);
    do_cmdline_cmd("redir END");

    char_u *output = get_vim_var_str(VV_COMMAND_OUTPUT);

    // FIXME: handle err.set == true
    NSData *outputData = [NSData dataWithBytes:output length:strlen((const char *) output)];

    NSMutableData *data = [NSMutableData dataWithBytes:&responseId length:sizeof(NSUInteger)];
    [data appendData:outputData];

    [_neovim_server sendMessageWithId:NeoVimServerMsgIdCommandOutputResult data:data];

    free(values); // malloc'ed in loop_schedule(&main_loop, ...) (in _queue) somewhere
    [input release]; // retained in loop_schedule(&main_loop, ...) (in _queue) somewhere
  }
}

static void neovim_input(void **argv) {
  @autoreleasepool {
    NSString *input = (NSString *) argv[0];

    // FIXME: check the length of the consumed bytes by neovim and if not fully consumed, call vim_input again.
    vim_input((String) {
        .data = (char *) input.cstr,
        .size = [input lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
    });

    [input release]; // retained in loop_schedule(&main_loop, ...) (in _queue) somewhere
  }
}

static void send_dirty_status() {
  bool new_dirty_status = server_has_dirty_docs();
  DLOG("dirty status: %d vs. %d", _dirty, new_dirty_status);
  if (_dirty == new_dirty_status) {
    return;
  }

  _dirty = new_dirty_status;
  DLOG("sending dirty status: %d", _dirty);
  NSData *data = [[NSData alloc] initWithBytes:&_dirty length:sizeof(bool)];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdDirtyStatusChanged data:data];
  [data release];
}

static void insert_marked_text(NSString *markedText) {
  _marked_text = [markedText retain]; // release when the final text is input in -vimInput

  loop_schedule(&main_loop, event_create(1, neovim_input, 1, [_marked_text retain])); // release in neovim_input
}

static void delete_marked_text() {
  NSUInteger length = [_marked_text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;

  [_marked_text release];
  _marked_text = nil;

  for (int i = 0; i < length; i++) {
    loop_schedule(&main_loop, event_create(1, neovim_input, 1, [_backspace retain])); // release in neovim_input
  }
}

static void run_neovim(void *arg __unused) {
  char *argv[1];
  argv[0] = "nvim";

  int returnCode = nvim_main(1, argv);

  NSLog(@"neovim's main returned with code: %d\n", returnCode);
}

#pragma mark Public

void custom_ui_start(void) {
  UI *ui = xcalloc(1, sizeof(UI));

  ui->rgb = true;
  ui->stop = server_ui_stop;
  ui->resize = server_ui_resize;
  ui->clear = server_ui_clear;
  ui->eol_clear = server_ui_eol_clear;
  ui->cursor_goto = server_ui_cursor_goto;
  ui->update_menu = server_ui_update_menu;
  ui->busy_start = server_ui_busy_start;
  ui->busy_stop = server_ui_busy_stop;
  ui->mouse_on = server_ui_mouse_on;
  ui->mouse_off = server_ui_mouse_off;
  ui->mode_change = server_ui_mode_change;
  ui->set_scroll_region = server_ui_set_scroll_region;
  ui->scroll = server_ui_scroll;
  ui->highlight_set = server_ui_highlight_set;
  ui->put = server_ui_put;
  ui->bell = server_ui_bell;
  ui->visual_bell = server_ui_visual_bell;
  ui->update_fg = server_ui_update_fg;
  ui->update_bg = server_ui_update_bg;
  ui->update_sp = server_ui_update_sp;
  ui->flush = server_ui_flush;
  ui->suspend = NULL;
  ui->set_title = server_ui_set_title;
  ui->set_icon = server_ui_set_icon;

  ui_bridge_attach(ui, server_ui_main, server_ui_scheduler);
}

void custom_ui_autocmds_groups(
    event_T event, char_u *fname, char_u *fname_io, int group, bool force, buf_T *buf, exarg_T *eap
) {
  @autoreleasepool {
    DLOG("got event %d for file %s in group %d.", event, fname, group);
    switch (event) {
      // Did we get them all?
      case EVENT_TEXTCHANGED:
      case EVENT_TEXTCHANGEDI:
      case EVENT_BUFWRITEPOST:
      case EVENT_BUFLEAVE:
        send_dirty_status();
        return;

      case EVENT_CWDCHANGED:
        [_neovim_server sendMessageWithId:NeoVimServerMsgIdCwdChanged];
        return;

      default:
        return;
    }
  }
}

void server_start_neovim() {
  _queue = dispatch_queue_create("com.qvacua.vimr.neovim-server.queue", DISPATCH_QUEUE_SERIAL);

  // set $VIMRUNTIME to ${RESOURCE_PATH_OF_XPC_BUNDLE}/runtime
  NSString *bundlePath = [NSBundle bundleForClass:[NeoVimServer class]].bundlePath;
  NSString *resourcesPath = [bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Resources"];
  NSString *runtimePath = [resourcesPath stringByAppendingPathComponent:@"runtime"];
  setenv("VIMRUNTIME", runtimePath.fileSystemRepresentation, true);

  uv_mutex_init(&_mutex);
  uv_cond_init(&_condition);

  uv_thread_create(&_nvim_thread, run_neovim, NULL);
  DLOG("NeoVim started");

  // continue only after our UI main code for neovim has been fully initialized
  uv_mutex_lock(&_mutex);
  while (!_is_ui_launched) {
    uv_cond_wait(&_condition, &_mutex);
  }
  uv_mutex_unlock(&_mutex);

  uv_cond_destroy(&_condition);
  uv_mutex_destroy(&_mutex);

  _backspace = [[NSString alloc] initWithString:@"<BS>"];

  bool value = msg_didany > 0;
  NSData *data = [[NSData alloc] initWithBytes:&value length:sizeof(bool)];
  [_neovim_server sendMessageWithId:NeoVimServerMsgIdNeoVimReady data:data];
  [data release];
}

void server_delete(NSInteger count) {
  queue(^{
    _marked_delta = 0;

    // Very ugly: When we want to have the Hanja for 하, Cocoa first finalizes 하, then sets the Hanja as marked text.
    // The main app will call this method when this happens, thus compute how many cell we have to go backward to
    // correctly mark the will-be-soon-inserted Hanja... See also docs/notes-on-cocoa-text-input.md
    int emptyCounter = 0;
    for (int i = 0; i < count; i++) {
      _marked_delta -= 1;

      // TODO: -1 because we assume that the cursor is one cell ahead, probably not always correct...
      schar_T character = ScreenLines[_put_row * screen_Rows + _put_column - i - emptyCounter - 1];
      if (character == 0x00 || character == ' ') {
        // FIXME: dunno yet, why we have to also match ' '...
        _marked_delta -= 1;
        emptyCounter += 1;
      }
    }

    DLOG("put cursor: %d:%d, count: %li, delta: %d", _put_row, _put_column, count, _marked_delta);

    for (int i = 0; i < count; i++) {
      loop_schedule(&main_loop, event_create(1, neovim_input, 1, [_backspace retain])); // release in neovim_input
    }
  });
}

void server_resize(int width, int height) {
  queue(^{
    set_ui_size(_server_ui_data->bridge, width, height);
    loop_schedule(&main_loop, event_create(1, refresh_ui, 0));
  });
}

void server_vim_command(NSString *input) {
  queue(^{
    loop_schedule(&main_loop, event_create(1, neovim_command, 1, [input retain])); // release in neovim_command
  });
}

void server_vim_command_output(NSUInteger responseId, NSString *input) {
  queue(^{
    // We could use (NSInteger *) responseId, but that would be almost unreadable and would rely on the fact that
    // (coincidentally) the pointers and NSUInteger are both 64bit wide.
    NSUInteger *values = malloc(sizeof(NSUInteger));
    values[0] = responseId;

    // free release in neovim_command
    loop_schedule(&main_loop, event_create(1, neovim_command_output, 2, values, [input retain]));
  });
}

void server_vim_input(NSString *input) {
  queue(^{
    if (_marked_text == nil) {
      loop_schedule(&main_loop, event_create(1, neovim_input, 1, [input retain])); // release in neovim_input
      return;
    }

    // Handle cases like ㅎ -> arrow key: The previously marked text is the same as the finalized text which should
    // inserted. Neovim's drawing code is optimized such that it does not call put in this case again, thus, we have
    // to manually unmark the cells in the main app.
    if ([_marked_text isEqualToString:input]) {
      DLOG("unmarking text: '%s'\t now at %d:%d", input.cstr, _put_row, _put_column);
      const char *str = _marked_text.cstr;
      size_t cellCount = mb_string2cells((const char_u *) str);
      for (int i = 1; i <= cellCount; i++) {
        DLOG("unmarking at %d:%d", _put_row, _put_column - i);
        int values[] = { _put_row, MAX(_put_column - i, 0) };
        NSData *data = [[NSData alloc] initWithBytes:values length:(2 * sizeof(int))];
        [_neovim_server sendMessageWithId:NeoVimServerMsgIdUnmark data:data];
        [data release];
      }
    }

    delete_marked_text();
    loop_schedule(&main_loop, event_create(1, neovim_input, 1, [input retain])); // release in neovim_input
  });
}

void server_vim_input_marked_text(NSString *markedText) {
  queue(^{
    if (_marked_text == nil) {
      _marked_row = _put_row;
      _marked_column = _put_column + _marked_delta;
      DLOG("marking position: %d:%d(%d + %d)", _put_row, _marked_column, _put_column, _marked_delta);
      _marked_delta = 0;
    } else {
      delete_marked_text();
    }

    DLOG("inserting marked text '%s' at %d:%d", markedText.cstr, _put_row, _put_column);
    insert_marked_text(markedText);
  });
}

bool server_has_dirty_docs() {
  FOR_ALL_BUFFERS(buffer) {
    if (buffer->b_p_bl == 0) {
      continue;
    }

    if (bufIsChanged(buffer)) {
      return true;
    }
  }

  return false;
}

NSString *server_escaped_filename(NSString *filename) {
  const char *file_system_rep = filename.fileSystemRepresentation;

  char_u *escaped_filename = vim_strsave_fnameescape((char_u *) file_system_rep, 0);
  NSString *result = [NSString stringWithCString:(const char *) escaped_filename encoding:NSUTF8StringEncoding];
  xfree(escaped_filename);

  return result;
}

NSArray *server_buffers() {
  NSMutableArray <NeoVimBuffer *> *result = [[NSMutableArray new] autorelease];
  FOR_ALL_BUFFERS(buf) {
    if (buf->b_p_bl == 0) {
      continue;
    }

    NSString *fileName = nil;
    if (buf->b_ffname != NULL) {
      fileName = [NSString stringWithCString:(const char *) buf->b_ffname encoding:NSUTF8StringEncoding];
    }
    bool current = curbuf == buf;
    NeoVimBuffer *buffer = [[NeoVimBuffer alloc] initWithHandle:(NSUInteger) buf->handle
                                                       fileName:fileName
                                                          dirty:buf->b_changed
                                                        current:current];
    [result addObject:buffer];
    [buffer release];
  }
  return result;
}

void server_quit() {
  DLOG("NeoVimServer exiting...");
  exit(0);
}
