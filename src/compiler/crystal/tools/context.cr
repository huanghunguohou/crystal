require "../syntax/ast"
require "../compiler"
require "json"

module Crystal
  class ContextResult
    json_mapping({
      status:           {type: String},
      message:          {type: String},
      contexts:         {type: Array(Hash(String, Type)), nilable: true},
    })

    def initialize(@status, @message)
    end
  end

  class ContextVisitor < Visitor
    getter contexts

    def initialize(@target_location)
      @contexts = Array(Hash(String, Type)).new
      @context = Hash(String, Type).new
    end

    def process(result : Compiler::Result)
      result.program.def_instances.each_value do |typed_def|
        visit_and_append_context typed_def
      end

      result.program.types.values.each do |type|
        if type.is_a?(DefInstanceContainer)
          type.def_instances.values.try do |typed_defs|
            typed_defs.each do |typed_def|
              if loc = typed_def.location
                if loc.filename == typed_def.end_location.try(&.filename) && contains_target(typed_def)
                  visit_and_append_context(typed_def) do
                    add_context "self", type
                    if type.is_a?(InstanceVarContainer)
                      type.instance_vars.values.each do |ivar|
                        add_context ivar.name, ivar.type
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      if @contexts.empty?
        @context = Hash(String, Type).new
        result.program.vars.each do |name, var|
          add_context name, var.type
        end
        result.node.accept(self)
        # TODO should apply only if user is really in some of the nodes of the main expressions
        @contexts << @context unless @context.empty?
      end

      if @contexts.empty?
        return ContextResult.new("failed", "no context information found")
      else
        res = ContextResult.new("ok", "#{@contexts.count} possible context#{@contexts.count > 1 ? "s" : ""} found")
        res.contexts = @contexts
        return res
      end
    end

    def visit_and_append_context(node)
      visit_and_append_context(node) { }
    end

    def visit_and_append_context(node, &block)
      @context = Hash(String, Type).new
      yield
      node.accept(self)
      @contexts << @context unless @context.empty?
    end

    def visit(node : Def)
      if contains_target(node)
        node.vars.try do |vars|
          vars.each do |name, meta_var|
            add_context name, meta_var.type
          end
        end
        return true
      end
    end

    def visit(node : Block)
      if contains_target(node)
        node.args.each do |arg|
          add_context arg.name, arg.type
        end
        return true
      end
    end

    def visit(node : Call)
      if node.location && @target_location.between?(node.name_location, node.name_end_location)
        add_context node.to_s, node.type
      end

      contains_target(node)
    end

    def visit(node)
      contains_target(node)
    end

    private def add_context(name, type)
      return if name.starts_with?("__temp_") # ignore temp vars
      return if name == "self" && type.to_s == "<Program>"

      @context[name] = type
    end

    private def contains_target(node)
      if loc_start = node.location
        loc_end = node.end_location || loc_start
        # if it is not between, it could be the case that node is the top level Expressions
        # in which the (start) location might be in one file and the end location in another.
        @target_location.between?(loc_start, loc_end) || loc_start.filename != loc_end.filename
      else
        # if node has no location, assume they may contain the target.
        # for example with the main expressions ast node this matters
        true
      end
    end
  end
end
