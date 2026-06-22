const path = require('path')
const webpack = require('webpack')
const HtmlWebpackPlugin = require('html-webpack-plugin')

module.exports = (_env, argv) => {
  const isDev = argv.mode !== 'production'

  return {
    entry: path.resolve(__dirname, 'src/renderer/app.ts'),
    target: 'electron-renderer',
    devtool: isDev ? 'eval-source-map' : 'source-map',
    output: {
      path: path.resolve(__dirname, 'dist/renderer'),
      filename: 'bundle.js',
      clean: true,
    },
    resolve: {
      extensions: ['.ts', '.tsx', '.js', '.jsx'],
      alias: {
        '@gather/shared': path.resolve(__dirname, '../packages/shared/src/index.ts'),
      },
    },
    module: {
      rules: [
        {
          test: /\.tsx?$/,
          use: {
            loader: 'ts-loader',
          options: {
            configFile: 'tsconfig.renderer.json',
            compilerOptions: {
              noEmit: false,
              allowImportingTsExtensions: false,
            },
          },
          },
          exclude: /node_modules/,
        },
        {
          test: /\.css$/,
          use: ['style-loader', 'css-loader'],
        },
      ],
    },
    plugins: [
      new webpack.DefinePlugin({
        'process.env.NODE_ENV': JSON.stringify(argv.mode),
      }),
      new HtmlWebpackPlugin({
        template: path.resolve(__dirname, 'src/renderer/index.html'),
      }),
    ],
    devServer: {
      port: 5173,
      hot: true,
      static: {
        directory: path.resolve(__dirname, 'dist/renderer'),
      },
    },
  }
}
