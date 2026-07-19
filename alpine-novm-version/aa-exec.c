#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/apparmor.h>

static void usage(const char *name)
{
	fprintf(stderr, "Usage: %s -p PROFILE COMMAND [ARG...]\n", name);
}

int main(int argc, char **argv)
{
	const char *profile = NULL;
	int option;

	while ((option = getopt(argc, argv, "p:")) != -1) {
		switch (option) {
		case 'p':
			profile = optarg;
			break;
		default:
			usage(argv[0]);
			return 2;
		}
	}

	if (profile == NULL || optind >= argc) {
		usage(argv[0]);
		return 2;
	}

	if (aa_change_onexec(profile) < 0) {
		fprintf(stderr, "%s: cannot switch to AppArmor profile %s: %s\n",
		        argv[0], profile, strerror(errno));
		return 1;
	}

	execvp(argv[optind], &argv[optind]);
	fprintf(stderr, "%s: cannot execute %s: %s\n",
	        argv[0], argv[optind], strerror(errno));
	return 1;
}
