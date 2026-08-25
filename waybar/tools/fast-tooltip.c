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
 *   gcc -shared -fPIC -O2 -o libfasttooltip.so fast-tooltip.c \
 *       $(pkg-config --cflags glib-2.0)
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <glib.h>

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

guint gdk_threads_add_timeout_full(gint priority, guint interval,
				   GSourceFunc function, gpointer data,
				   GDestroyNotify notify)
{
	static add_timeout_full_fn real;
	guint id;

	if (!real)
		real = (add_timeout_full_fn)dlsym(RTLD_NEXT,
						  "gdk_threads_add_timeout_full");

	if (function == popup_fn && interval == HOVER_TIMEOUT)
		interval = delay_ms();

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
