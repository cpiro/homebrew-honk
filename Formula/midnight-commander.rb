class MidnightCommander < Formula
  desc "Terminal-based visual file manager"
  homepage "https://www.midnight-commander.org/"
  url "https://www.midnight-commander.org/downloads/mc-4.8.21.tar.xz"
  sha256 "8f37e546ac7c31c9c203a03b1c1d6cb2d2f623a300b86badfd367e5559fe148c"
  head "https://github.com/MidnightCommander/mc.git"

  option "without-nls", "Build without Native Language Support"

  depends_on "pkg-config" => :build
  depends_on "glib"
  depends_on "libssh2"
  depends_on "openssl"
  depends_on "s-lang"

  conflicts_with "minio-mc", :because => "Both install a `mc` binary"

  patch :DATA

  def install
    args = %W[
      --disable-debug
      --disable-dependency-tracking
      --disable-silent-rules
      --prefix=#{prefix}
      --without-x
      --with-screen=slang
      --enable-vfs-sftp
    ]

    # Fix compilation bug on macOS 10.13 by pretending we don't have utimensat()
    # https://github.com/MidnightCommander/mc/pull/130
    ENV["ac_cv_func_utimensat"] = "no" if MacOS.version >= :high_sierra

    args << "--disable-nls" if build.without? "nls"

    system "./configure", *args
    system "make", "install"
  end

  test do
    assert_match "GNU Midnight Commander", shell_output("#{bin}/mc --version")
  end
end

__END__
diff --git a/src/execute.c b/src/execute.c
index 999ae0eb6..0f43950a0 100644
--- a/src/execute.c
+++ b/src/execute.c
@@ -328,7 +328,10 @@ do_executev (const char *shell, int flags, char *const argv[])
     {
         if ((pause_after_run == pause_always
              || (pause_after_run == pause_on_dumb_terminals && !mc_global.tty.xterm_flag
-                 && mc_global.tty.console_flag == '\0')) && quit == 0
+                 && mc_global.tty.console_flag == '\0')
+             || (pause_after_run == pause_on_output && did_read_subshell > 0)
+             )
+            && quit == 0
 #ifdef ENABLE_SUBSHELL
             && subshell_state != RUNNING_COMMAND
 #endif /* ENABLE_SUBSHELL */
diff --git a/src/execute.h b/src/execute.h
index 56d24c546..4cf53d3a5 100644
--- a/src/execute.h
+++ b/src/execute.h
@@ -17,7 +17,8 @@ enum
 {
     pause_never,
     pause_on_dumb_terminals,
-    pause_always
+    pause_always,
+    pause_on_output
 };

 /*** structures declarations (and typedefs of structures)*****************************************/
diff --git a/src/filemanager/boxes.c b/src/filemanager/boxes.c
index a8f4e00e7..9f030c8e5 100644
--- a/src/filemanager/boxes.c
+++ b/src/filemanager/boxes.c
@@ -500,7 +500,8 @@ configure_box (void)
     const char *pause_options[] = {
         N_("&Never"),
         N_("On dum&b terminals"),
-        N_("Alwa&ys")
+        N_("Alwa&ys"),
+        N_("On output only")
     };

     int pause_options_num;
@@ -550,6 +551,7 @@ configure_box (void)
                     QUICK_CHECKBOX (N_("A&uto save setup"), &auto_save_setup, NULL),
                     QUICK_SEPARATOR (FALSE),
                     QUICK_SEPARATOR (FALSE),
+                    QUICK_SEPARATOR (FALSE),
                 QUICK_STOP_GROUPBOX,
             QUICK_STOP_COLUMNS,
             QUICK_BUTTONS_OK_CANCEL,
diff --git a/src/subshell/common.c b/src/subshell/common.c
index 6a90c3e8a..e6b9d2acc 100644
--- a/src/subshell/common.c
+++ b/src/subshell/common.c
@@ -117,6 +117,10 @@ GString *subshell_prompt = NULL;
 /* We need to paint it after CONSOLE_RESTORE, see: load_prompt */
 gboolean update_subshell_prompt = FALSE;

+/* Bytes of command output read from subshell. We subtract away bytes written
+ * so we don't count the echo as output */
+int did_read_subshell = 0;
+
 /*** file scope macro definitions ****************************************************************/

 #ifndef WEXITSTATUS
@@ -565,6 +569,9 @@ feed_subshell (int how, gboolean fail_on_error)
             /* for (i=0; i<5; ++i)  * FIXME -- experimental */
         {
             bytes = read (mc_global.tty.subshell_pty, pty_buffer, sizeof (pty_buffer));
+            if (bytes > 0) {
+                did_read_subshell += bytes;
+            }

             /* The subshell has died */
             if (bytes == -1 && errno == EIO && !subshell_alive)
@@ -1143,6 +1150,8 @@ init_subshell (void)
 int
 invoke_subshell (const char *command, int how, vfs_path_t ** new_dir_vpath)
 {
+    did_read_subshell = 0;
+
     /* Make the MC terminal transparent */
     tcsetattr (STDOUT_FILENO, TCSANOW, &raw_mode);

@@ -1157,17 +1166,21 @@ invoke_subshell (const char *command, int how, vfs_path_t ** new_dir_vpath)
             subshell_state = ACTIVE;
             /* FIXME: possibly take out this hack; the user can
                re-play it by hitting C-hyphen a few times! */
-            if (subshell_ready)
-                write_all (mc_global.tty.subshell_pty, " \b", 2);       /* Hack to make prompt reappear */
+            if (subshell_ready) {
+                /* Hack to make prompt reappear */
+                did_read_subshell -= write_all (mc_global.tty.subshell_pty, " \b", 2);
+            }
         }
     }
     else                        /* MC has passed us a user command */
     {
-        if (how == QUIETLY)
-            write_all (mc_global.tty.subshell_pty, " ", 1);
+        if (how == QUIETLY) {
+            did_read_subshell -= write_all (mc_global.tty.subshell_pty, " ", 1);
+        }
         /* FIXME: if command is long (>8KB ?) we go comma */
-        write_all (mc_global.tty.subshell_pty, command, strlen (command));
+        did_read_subshell -= write_all (mc_global.tty.subshell_pty, command, strlen (command));
         write_all (mc_global.tty.subshell_pty, "\n", 1);
+        did_read_subshell -= 2;  // echo will be \r\n
         subshell_state = RUNNING_COMMAND;
         subshell_ready = FALSE;
     }
diff --git a/src/subshell/subshell.h b/src/subshell/subshell.h
index e0fdfb13e..f95491f11 100644
--- a/src/subshell/subshell.h
+++ b/src/subshell/subshell.h
@@ -35,6 +35,7 @@ extern enum subshell_state_enum subshell_state;
 extern GString *subshell_prompt;

 extern gboolean update_subshell_prompt;
+extern int did_read_subshell;

 /*** declarations of public functions ************************************************************/

