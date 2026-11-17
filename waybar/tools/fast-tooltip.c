/*
 * fast-tooltip -- make Waybar's tooltips appear on hover instead of half a
 * second later.
 *
 * GTK3 has no setting for this. gtk-tooltip-timeout was deprecated in 3.10 and
 * gtktooltip.c stopped reading it -- measured on gtk3-3.24.52, setting it to 0
 * still gives 521ms. The delay is the compile-time HOVER_TIMEOUT of 500ms.
 *
 * gtk_tooltip_start_delay() arms that timeout through
 * gdk_threads_add_timeout_full(), which crosses from libgtk-3 into libgdk-3 --
 * an ordinary PLT call, so LD_PRELOAD can interpose it.
 *
 * Picking the right timer out of that stream is the fiddly part. The hover
 * timer and the browse-mode expiry are both armed at priority 0 with an
 * interval of exactly 500, so neither number identifies it. What does is the
 * g_source_set_name_by_id() call GTK makes immediately afterwards: the hover
 * timer is named "[gtk+] tooltip_popup_timeout" and the other one is not.
 * Hooking that too lets this learn the callback address at runtime rather than
 * guessing at a constant, and from then on only that callback is shortened.
 *
 * The first arm of the very first hover still runs at 500ms, since the name
 * only arrives after the source exists. It does not show: GTK re-arms the
 * timer on every motion event, so by the second arm the address is known and
 * the tooltip lands in ~130ms, ~70ms on later hovers.
 *
 * Everything here fails open. If GTK renames the source or stops naming it,
 * nothing ever matches, every call is passed through untouched, and tooltips
 * are merely slow again.
 *
 * Delay in ms via GTK_TOOLTIP_DELAY_MS, default 50.
 *
 * Quickshell popups. Modules named in WAYBAR_QS_TOOLTIPS (space separated
 * CSS ids, e.g. "custom-cpu") get no GTK tooltip: when GTK is about to show
 * one, the module's position goes to Quickshell over a unix socket instead
 * ($XDG_RUNTIME_DIR/waybar-tooltips.sock), and Quickshell draws an
 * interactive popup under the module. One line per event:
 *
 *   enter <module> <monitor-x> <monitor-y> <module-x> <module-width> <bar-height>
 *   leave
 *
 * "leave" comes from polling the pointer every 30ms while a popup is up; GTK
 * has no leave hook we can reach. If nothing listens on the socket the GTK
 * tooltip is left alone, so stopping Quickshell gives the old tooltip back.
 *
 *   gcc -shared -fPIC -O2 -o libfasttooltip.so fast-tooltip.c \
 *       $(pkg-config --cflags gtk+-3.0)
 *
 * Nothing is linked: the GTK calls resolve lazily against the waybar they are
 * preloaded into, and the scripts waybar spawns inherit LD_PRELOAD without
 * ever calling them.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <gtk/gtk.h>

#define TOOLTIP_SOURCE_NAME "[gtk+] tooltip_popup_timeout"
#define HOVER_TIMEOUT       500
#define DEFAULT_DELAY_MS    50

typedef guint (*add_timeout_full_fn)(gint, guint, GSourceFunc, gpointer,
				     GDestroyNotify);
typedef void (*set_name_by_id_fn)(guint, const char *);

static GSourceFunc popup_fn;
static guint pending_id;
static GSourceFunc pending_fn;

static guint delay_ms(void)
{
	static guint cached;
	const char *env;
	char *end;
	long v;

	if (cached)
		return cached;

	cached = DEFAULT_DELAY_MS;
	env = getenv("GTK_TOOLTIP_DELAY_MS");
	if (env && *env) {
		v = strtol(env, &end, 10);
		if (*end == '\0' && v >= 0 && v <= 5000)
			cached = (guint)v;
	}
	return cached;
}

/* ---- Quickshell popups ------------------------------------------------ */

static int qs_fd = -1;
static char qs_module[64];	/* module handed to Quickshell, "" if none */
static guint qs_poll_id;

static gboolean qs_send(const char *line)
{
	size_t len = strlen(line);
	const char *dir;
	struct sockaddr_un addr = { .sun_family = AF_UNIX };

	for (int attempt = 0; attempt < 2; attempt++) {
		if (qs_fd < 0) {
			dir = getenv("XDG_RUNTIME_DIR");
			if (!dir)
				return FALSE;
			snprintf(addr.sun_path, sizeof addr.sun_path,
				 "%s/waybar-tooltips.sock", dir);
			qs_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
			if (qs_fd < 0)
				return FALSE;
			if (connect(qs_fd, (struct sockaddr *)&addr,
				    sizeof addr) < 0) {
				close(qs_fd);
				qs_fd = -1;
				return FALSE;
			}
		}
		if (send(qs_fd, line, len, MSG_NOSIGNAL | MSG_DONTWAIT) ==
		    (ssize_t)len)
			return TRUE;
		/* Quickshell restarted: reconnect once */
		close(qs_fd);
		qs_fd = -1;
	}
	return FALSE;
}

static gboolean qs_handled(const char *name)
{
	const char *list = getenv("WAYBAR_QS_TOOLTIPS");
	size_t n;

	if (!list || !name || !*name)
		return FALSE;
	n = strlen(name);
	for (const char *p = list; (p = strstr(p, name)); p += n)
		if ((p == list || p[-1] == ' ') && (p[n] == '\0' || p[n] == ' '))
			return TRUE;
	return FALSE;
}

/* The waybar module (the widget carrying the CSS id) under the pointer. */
static GtkWidget *qs_module_under_pointer(GdkDisplay *display)
{
	GdkSeat *seat = gdk_display_get_default_seat(display);
	GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
	GdkWindow *win;
	gpointer data = NULL;
	GtkWidget *child;

	if (!pointer)
		return NULL;
	win = gdk_device_get_window_at_position(pointer, NULL, NULL);
	if (!win)
		return NULL;
	gdk_window_get_user_data(win, &data);

	for (GtkWidget *w = data; w; w = gtk_widget_get_parent(w)) {
		if (qs_handled(gtk_widget_get_name(w)))
			return w;
		/* waybar names the label, the event box above it has the window */
		if (GTK_IS_BIN(w)) {
			child = gtk_bin_get_child(GTK_BIN(w));
			if (child && qs_handled(gtk_widget_get_name(child)))
				return child;
		}
	}
	return NULL;
}

static void qs_hide_gtk_tooltip(void)
{
	GList *tops = gtk_window_list_toplevels();

	for (GList *l = tops; l; l = l->next)
		if (strcmp(G_OBJECT_TYPE_NAME(l->data), "GtkTooltipWindow") == 0 &&
		    gtk_widget_get_visible(l->data))
			gtk_widget_hide(l->data);
	g_list_free(tops);
}

static gboolean qs_poll(gpointer display)
{
	GtkWidget *w = qs_module_under_pointer(display);

	if (w && strcmp(gtk_widget_get_name(w), qs_module) == 0)
		return G_SOURCE_CONTINUE;

	qs_send("leave\n");
	qs_module[0] = '\0';
	qs_poll_id = 0;
	return G_SOURCE_REMOVE;
}

/*
 * Runs in place of GTK's tooltip_popup_timeout. GTK still shows its tooltip
 * (that keeps its own bookkeeping straight), and for a handed-over module it
 * is hidden again before the next frame is drawn, so it never appears.
 */
static gboolean qs_popup_trampoline(gpointer data)
{
	GdkDisplay *display = data;
	GtkWidget *w = qs_module_under_pointer(display);
	gboolean ret = popup_fn(data);
	GtkWidget *top;
	GdkMonitor *mon;
	GdkRectangle geo = { 0 };
	int x = 0, y = 0;
	char line[256];

	if (!w)
		return ret;

	if (strcmp(gtk_widget_get_name(w), qs_module) != 0) {
		top = gtk_widget_get_toplevel(w);
		mon = gdk_display_get_monitor_at_window(display,
						gtk_widget_get_window(top));
		if (mon)
			gdk_monitor_get_geometry(mon, &geo);
		gtk_widget_translate_coordinates(w, top, 0, 0, &x, &y);
		snprintf(line, sizeof line, "enter %s %d %d %d %d %d\n",
			 gtk_widget_get_name(w), geo.x, geo.y, x,
			 gtk_widget_get_allocated_width(w),
			 gtk_widget_get_allocated_height(top));
		if (!qs_send(line))
			return ret;	/* nobody listening: keep the GTK tooltip */
		g_strlcpy(qs_module, gtk_widget_get_name(w), sizeof qs_module);
		if (!qs_poll_id)
			qs_poll_id = g_timeout_add(30, qs_poll, display);
	}
	qs_hide_gtk_tooltip();
	return ret;
}

guint gdk_threads_add_timeout_full(gint priority, guint interval,
				   GSourceFunc function, gpointer data,
				   GDestroyNotify notify)
{
	static add_timeout_full_fn real;
	guint id;

	if (!real)
		real = (add_timeout_full_fn)dlsym(RTLD_NEXT,
						  "gdk_threads_add_timeout_full");

	if (popup_fn && function == popup_fn) {
		if (interval == HOVER_TIMEOUT)
			interval = delay_ms();
		if (getenv("WAYBAR_QS_TOOLTIPS"))
			function = qs_popup_trampoline;
	}

	id = real(priority, interval, function, data, notify);

	if (interval == HOVER_TIMEOUT || function == popup_fn) {
		pending_id = id;
		pending_fn = function;
	}
	return id;
}

void g_source_set_name_by_id(guint id, const char *name)
{
	static set_name_by_id_fn real;

	if (!real)
		real = (set_name_by_id_fn)dlsym(RTLD_NEXT,
						"g_source_set_name_by_id");

	if (!popup_fn && id == pending_id && name &&
	    strcmp(name, TOOLTIP_SOURCE_NAME) == 0)
		popup_fn = pending_fn;

	real(id, name);
}
