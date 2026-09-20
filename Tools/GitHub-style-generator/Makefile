SASS = node_modules/.bin/sass

target = ../../MacDown/Resources/Styles/GitHub-2020.css

all: $(target)

# The generated CSS is committed, so a plain build needs no Node toolchain.
# Run `npm install` here first if you want to regenerate it from index.sass.
$(target): index.sass package-lock.json
	$(SASS) --no-source-map --quiet-deps --silence-deprecation=import \
	    --load-path=node_modules $< \
	    | sed s/.markdown-body/body/ > $@

clean:
	$(RM) $(target)

.PHONY: all clean
