# Adds given `Kemal::Handler` to handlers chain.
# There are 5 handlers by default and all the custom handlers
# goes between the first 4 and the last `Kemal::RouteHandler`.
#
# - `Kemal::InitHandler`
# - `Kemal::LogHandler`
# - `Kemal::ExceptionHandler`
# - `Kemal::StaticFileHandler`
# - Here goes custom handlers
# - `Kemal::RouteHandler`
def add_handler(handler : HTTP::Handler)
  Kemal.config.add_handler handler
end

def add_handler(handler : HTTP::Handler, position : Int32)
  Kemal.config.add_handler handler, position
end

# Sets public folder from which the static assets will be served.
#
# By default this is `/public` not `src/public`.
def public_folder(path : String)
  Kemal.config.public_folder = path
end

# Logs the output via `logger`.
# This is the built-in `Kemal::LogHandler` by default which uses STDOUT.
def log(message : String)
  Kemal.config.logger.write "#{message}\n"
end

# Enables / Disables logging.
# This is enabled by default.
#
# ```
# logging false
# ```
def logging(status : Bool)
  Kemal.config.logging = status
end

# This is used to replace the built-in `Kemal::LogHandler` with a custom logger.
#
# A custom logger must inherit from `Kemal::BaseLogHandler` and must implement
# `call(env)`, `write(message)` methods.
#
# ```
# class MyCustomLogger < Kemal::BaseLogHandler
#   def call(env)
#     puts "I'm logging some custom stuff here."
#     call_next(env) # => This calls the next handler
#   end
#
#   # This is used from `log` method.
#   def write(message)
#     STDERR.puts message # => Logs the output to STDERR
#   end
# end
# ```
#
# Now that we have a custom logger here's how we use it
#
# ```
# logger MyCustomLogger.new
# ```
def logger(logger : Kemal::BaseLogHandler)
  Kemal.config.logger = logger
  Kemal.config.add_handler logger
end

# Enables / Disables static file serving.
# This is enabled by default.
#
# ```
# serve_static false
# ```
#
# Static server also have some advanced customization options like `dir_listing` and
# `gzip`.
#
# ```
# serve_static {"gzip" => true, "dir_listing" => false}
# ```
def serve_static(status : (Bool | Hash))
  Kemal.config.serve_static = status
end

# Helper for easily modifying response headers.
# This can be used to modify a response header with the given hash.
#
# ```
# def call(env)
#   headers(env, {"X-Custom-Header" => "This is a custom value"})
# end
# ```
def headers(env : HTTP::Server::Context, additional_headers : Hash(String, String))
  env.response.headers.merge!(additional_headers)
end

# Send a file with given path and base the mime-type on the file extension
# or default `application/octet-stream` mime_type.
#
# ```
# send_file env, "./path/to/file"
# ```
#
# Optionally you can override the mime_type
#
# ```
# send_file env, "./path/to/file", "image/jpeg"
# ```
def send_file(env : HTTP::Server::Context, path : String, mime_type : String? = nil)
  config = Kemal.config.serve_static
  file_path = File.expand_path(path, Dir.current)
  mime_type ||= Kemal::Utils.mime_type(file_path)
  env.response.content_type = mime_type
  env.response.headers["Accept-Ranges"] = "bytes"
  env.response.headers["X-Content-Type-Options"] = "nosniff"
  minsize = 860 # http://webmasters.stackexchange.com/questions/31750/what-is-recommended-minimum-object-size-for-gzip-performance-benefits ??
  request_headers = env.request.headers
  filesize = File.size(file_path)
  filestat = File.stat(file_path)

  Kemal.config.static_headers.try(&.call(env.response, file_path, filestat))

  File.open(file_path) do |file|
    if env.request.method == "GET" && env.request.headers.has_key?("Range")
      next multipart(file, env)
    end
    if request_headers.includes_word?("Accept-Encoding", "gzip") && config.is_a?(Hash) && config["gzip"] == true && filesize > minsize && Kemal::Utils.zip_types(file_path)
      env.response.headers["Content-Encoding"] = "gzip"
      Gzip::Writer.open(env.response) do |deflate|
        IO.copy(file, deflate)
      end
    elsif request_headers.includes_word?("Accept-Encoding", "deflate") && config.is_a?(Hash) && config["gzip"]? == true && filesize > minsize && Kemal::Utils.zip_types(file_path)
      env.response.headers["Content-Encoding"] = "deflate"
      Flate::Writer.open(env.response) do |deflate|
        IO.copy(file, deflate)
      end
    else
      env.response.content_length = filesize
      IO.copy(file, env.response)
    end
  end
  return
end

private def multipart(file, env : HTTP::Server::Context)
  # See http://httpwg.org/specs/rfc7233.html
  fileb = file.size

  range = env.request.headers["Range"]
  match = range.match(/bytes=(\d{1,})-(\d{0,})/)

  startb = 0
  endb = 0

  if match
    if match.size >= 2
      startb = match[1].to_i { 0 }
    end

    if match.size >= 3
      endb = match[2].to_i { 0 }
    end
  end

  if endb == 0
    endb = fileb - 1
  end

  if startb < endb && endb < fileb
    content_length = 1 + endb - startb
    env.response.status_code = 206
    env.response.content_length = content_length
    env.response.headers["Accept-Ranges"] = "bytes"
    env.response.headers["Content-Range"] = "bytes #{startb}-#{endb}/#{fileb}" # MUST

    if startb > 1024
      skipped = 0
      # file.skip only accepts values less or equal to 1024 (buffer size, undocumented)
      until skipped + 1024 > startb
        file.skip(1024)
        skipped += 1024
      end
      if skipped - startb > 0
        file.skip(skipped - startb)
      end
    else
      file.skip(startb)
    end

    IO.copy(file, env.response, content_length)
  else
    env.response.content_length = fileb
    env.response.status_code = 200 # Range not satisfable, see 4.4 Note
    IO.copy(file, env.response)
  end
end

# Send a file with given data and default `application/octet-stream` mime_type.
#
# ```
# send_file env, data_slice
# ```
#
# Optionally you can override the mime_type
#
# ```
# send_file env, data_slice, "image/jpeg"
# ```
def send_file(env : HTTP::Server::Context, data : Slice(UInt8), mime_type : String? = nil)
  mime_type ||= "application/octet-stream"
  env.response.content_type = mime_type
  env.response.content_length = data.bytesize
  env.response.write data
end

# Configures an `HTTP::Server::Response` to compress the response
# output, either using gzip or deflate, depending on the `Accept-Encoding` request header.
#
# Disabled by default.
def gzip(status : Bool = false)
  add_handler HTTP::CompressHandler.new if status
end

# Adds headers to `Kemal::StaticFileHandler`. This is especially useful for `CORS`.
#
# ```
# static_headers do |response, filepath, filestat|
#   if filepath =~ /\.html$/
#     response.headers.add("Access-Control-Allow-Origin", "*")
#   end
#   response.headers.add("Content-Size", filestat.size.to_s)
# end
# ```
def static_headers(&headers : HTTP::Server::Response, String, File::Stat -> Void)
  Kemal.config.static_headers = headers
end
