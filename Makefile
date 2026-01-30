# Makefile for sd_viavoice - Speech Dispatcher module for ViaVoice TTS

CC = gcc
CFLAGS = -m32 -Wall -Wextra -O2 -fPIC -g
LDFLAGS = -m32

# Source directory
SRCDIR = src

# Build directory
BUILDDIR = build

# ViaVoice library (expected in deps/viavoice/lib after running build-bundle.sh)
VIAVOICE_LIB = deps/viavoice/lib
VIAVOICE_LIBS = -l:libibmeci50.so

# Include paths
INCLUDES = -I$(SRCDIR) -I/usr/include/speech-dispatcher

# Libraries
LIBS = -L$(VIAVOICE_LIB) \
       -Wl,-rpath,'$$ORIGIN/../lib' \
       $(VIAVOICE_LIBS) \
       -lpthread

# Target
TARGET = $(BUILDDIR)/sd_viavoice.bin

# Sources
SRCS = $(SRCDIR)/sd_viavoice.c \
       $(SRCDIR)/module_main.c \
       $(SRCDIR)/module_readline.c \
       $(SRCDIR)/module_process.c

OBJS = $(SRCS:$(SRCDIR)/%.c=$(BUILDDIR)/%.o)

.PHONY: all clean

all: $(BUILDDIR) $(TARGET)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS)
	@echo "Built: $@"
	@file $@

$(BUILDDIR)/%.o: $(SRCDIR)/%.c | $(BUILDDIR)
	$(CC) $(CFLAGS) $(INCLUDES) -c -o $@ $<

clean:
	rm -rf $(BUILDDIR)

# For local development - requires ViaVoice libs in deps/
dev: all
	@echo "Binary ready at $(TARGET)"
	@ldd $(TARGET) 2>&1 | head -10
