require 'pathname'
require 'asciidoctor/extensions'

autoload :Digest, 'digest'
autoload :Mathematical, 'mathematical'

class MathematicalTreeprocessor < Asciidoctor::Extensions::Treeprocessor
  LineFeed = %(\n)
  StemInlineMacroRx = /\\?(?:stem|latexmath|asciimath):([a-z,]*)\[(.*?[^\\])\]/m
  
  def process document
    format = ((document.attr 'mathematical-format') || 'png').to_sym
    if format != :png and format != :svg
      warn %(Unknown format '#{format}', retreat to 'png')
      format = :png
    end
    ppi = ((document.attr 'mathematical-ppi') || '300.0').to_f
    ppi = format == :png ? ppi : 72.0
    inline = document.attr 'mathematical-inline'
    if inline and format == :png
      warn 'Can\'t use mathematical-inline together with mathematical-format=png'
    end
    # The no-args constructor defaults to SVG and standard delimiters ($..$ for inline, $$..$$ for block)
    mathematical = ::Mathematical.new format: format, ppi: ppi
    
    unless (stem_blocks = document.find_by context: :stem).nil_or_empty?
      stem_blocks.each do |stem|
        handle_stem_block stem, mathematical, format, inline
      end
    end

    unless (prose_blocks = document.find_by {|b|
      (b.content_model == :simple && (b.subs.include? :macros)) || b.context == :list_item
    }).nil_or_empty?
      prose_blocks.each do |prose|
        handle_prose_block prose, mathematical, format, inline
      end
    end

    # handle table cells of the "asciidoc" type, as suggested by mojavelinux
    # at asciidoctor/asciidoctor-mathematical#20.
    unless (table_blocks = document.find_by context: :table).nil_or_empty?
      table_blocks.each do |table|
        (table.rows[:body] + table.rows[:foot]).each do |row|
          row.each do |cell|
            if cell.style == :asciidoc
              process cell.inner_document
            elsif cell.style != :literal
              handle_nonasciidoc_table_cell cell, mathematical, format, inline
            end
          end
        end
      end
    end

    unless (sect_blocks = document.find_by content: :section).nil_or_empty?
      sect_blocks.each do |sect|
        handle_section_title sect, mathematical, format, inline
      end
    end

    nil
  end

  def handle_stem_block(stem, mathematical, format, inline)
    equation_type = stem.style.to_sym
    
    img_target, img_width, img_height = make_equ_image stem, stem.content, stem.id, false, mathematical, format, inline

    parent = stem.parent
    if inline
      stem_image = create_pass_block parent, %{<div class="stemblock"> #{img_target} </div>}, {}
      parent.blocks[parent.blocks.index stem] = stem_image
    else
      alt_text = stem.attr 'alt', %($$#{stem.content}$$)
      attrs = {'target' => img_target, 'alt' => alt_text, 'align' => 'center'}
      # NOTE: The following setups the *intended width and height in pixel* for png images, which can be different that that of the generated image when PPIs larger than 72.0 is used.
      if format == :png
        attrs['width'] = %(#{img_width})
        attrs['height'] = %(#{img_height})
      end
      parent = stem.parent
      stem_image = create_image_block parent, attrs
      stem_image.id = stem.id if stem.id
      if (title = stem.attributes['title'])
        stem_image.title = title
      end
      parent.blocks[parent.blocks.index stem] = stem_image
    end
  end

  def handle_prose_block(prose, mathematical, format, inline)
    text = prose.context == :list_item ? (prose.instance_variable_get :@text) : (prose.lines * LineFeed)
    text, source_modified = handle_inline_stem prose, text, mathematical, format, inline
    if source_modified
      if prose.context == :list_item
        prose.instance_variable_set :@text, text
      else
        prose.lines = text.split LineFeed
      end
    end
  end

  def handle_nonasciidoc_table_cell(cell, mathematical, format, inline)
    text = cell.instance_variable_get :@text
    text, source_modified = handle_inline_stem cell, text, mathematical,  format, inline
    if source_modified
      cell.instance_variable_set :@text, text
    end
  end

  def handle_section_title(sect, mathematical, format, inline)
    text = sect.instance_variable_get :@title
    text, source_modified = handle_inline_stem sect, text, mathematical, format, inline
    if source_modified
      sect.instance_variable_set :@title, text
      sect.instance_variable_set :@title_converted, false
    end
  end

  def handle_inline_stem(node, text, mathematical, format, inline)
    document = node.document
    to_html = document.basebackend? 'html'
    
    source_modified = false
    # TODO skip passthroughs in the source (e.g., +stem:[x^2]+)
    text.gsub!(StemInlineMacroRx) {
      if (m = $~)[0].start_with? '\\'
        next m[0][1..-1]
      end

      if (eq_data = m[2].rstrip).empty?
        next
      else
        source_modified = true
      end

      eq_data.gsub! '\]', ']'
      subs = m[1].nil_or_empty? ? (to_html ? [:specialcharacters] : []) : (node.resolve_pass_subs m[1])
      eq_data = node.apply_subs eq_data, subs unless subs.empty?
      img_target, img_width, img_height = make_equ_image node, eq_data, nil, true, mathematical, format, inline
      if inline
        %(pass:[<span class="steminline"> #{img_target} </span>])
      else
        %(image:#{img_target}[width=#{img_width},height=#{img_height}])
      end
    } if (text != nil) && (text.include? ':') && ((text.include? 'stem:') || (text.include? 'latexmath:') || (text.include? 'asciimath:'))

    [text, source_modified]
  end

  def make_equ_image(node, equ_data, equ_id, equ_inline, mathematical, format, inline)
    input = equ_inline ? %($#{equ_data}$) : %($$#{equ_data}$$)
    
    parent = node.parent
    # TODO: Handle exceptions.
    result = mathematical.parse input
    if inline
      result[:data]
    else
      image_output_dir = image_output parent
      ::Asciidoctor::Helpers.mkdir_p image_output_dir unless ::File.directory? image_output_dir
      unless equ_id
        equ_id = %(stem-#{::Digest::MD5.hexdigest input})
      end
      image_ext = %(.#{format})
      img_target = %(#{equ_id}#{image_ext})
      img_file = ::File.join image_output_dir, img_target

      ::IO.write img_file, result[:data]

      [img_file, result[:width], result[:height]]
    end
  end

  def image_output(parent)
    document = parent.document

    output_dir = parent.attr('imagesoutdir')
    if output_dir
      base_dir = nil
    else
      base_dir = parent.attr('outdir') || (document.respond_to?(:options) && document.options[:to_dir])
      output_dir = parent.attr('imagesdir')
    end

    output_dir = parent.normalize_system_path(output_dir, base_dir)
    return output_dir
  end

end
